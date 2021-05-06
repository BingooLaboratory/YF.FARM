const func = async ({ getNamedAccounts, deployments, network }) => {
  const { AddressZero } = ethers.constants;
  const { deploy, get, execute } = deployments;
  const { deployer, governor, custodian, boardroom } = await getNamedAccounts();

  const yToken = await get('YFToken');
  const yfPool  = await get('YFPool');

  // 获取 Heco LP 机枪池列表
  const HecoPool = await ethers.getContractFactory("HecoPool");
  const hecoPool = new ethers.Contract('0xFB03e11D93632D97a8981158A632Dd5986F5E909', HecoPool.interface, ethers.provider);
  const MdexPair = await ethers.getContractFactory("contracts/mock/MockMdexPair.sol:MdexPair");

  // Mdex: Router
  const router = '0xED7d5F38C79115ca12fe6C0041abb22F0A06C300';
  const poolen = await hecoPool.poolLength().then(n => n.toNumber());
  const earned = await hecoPool.mdx();

  for (let i = 0; i < poolen; i++) {
    const poolInfo = await hecoPool.poolInfo(i);
    const { allocPoint, lpToken: desire } = poolInfo;

    // 单币复投
    if (i === 1) {
      const strat = await deploy('StratX', {
        from: governor,
        args: [
          router,
          yfPool.address,
          yToken.address,
          true,             // isErc20Token: 单币 = true, lp = false
          true,             // isAutoComp: 自动复投
          hecoPool.address, // 源机枪池
          i,                // 源机枪池Id
          desire,           // deposit token
          AddressZero,      // lp token0
          AddressZero,      // lp token1
          earned            // 源机枪池平台币
        ]
      });

      // YF 回购保管地址
      await execute(
        'StratX',
        { from: governor },
        'setFundsAccount',
        boardroom,
        custodian
      );

      // add to YF pool
      await execute(
        'YFPool',
        { from: deployer },
        'add',
        true,         // _withUpdate
        0,            // _allocYPoint
        0,            // _allocUPoint
        100,          // _allocBPoint
        desire,       // deposit token
        earned,
        strat.address // 策略
      );
    }

    // 单币质押
    if (i === 2) {
      const strat = await deploy('StratX', {
        from: governor,
        args: [
          router,
          yfPool.address,
          yToken.address,
          true,             // isErc20Token: 单币 = true, lp = false
          false,            // isAutoComp: 自动复投
          hecoPool.address, // 源机枪池
          i,                // 源机枪池Id
          desire,           // deposit token
          AddressZero,      // lp token0
          AddressZero,      // lp token1
          AddressZero       // 源机枪池平台币
        ]
      });

      // YF 回购保管地址
      await execute(
        'StratX',
        { from: governor },
        'setFundsAccount',
        boardroom,
        custodian
      );

      // add to YF pool
      await execute(
        'YFPool',
        { from: deployer },
        'add',
        true,         // _withUpdate
        100,          // _allocYPoint
        100,          // _allocUPoint
        0,            // _allocBPoint
        desire,       // deposit token
        AddressZero,
        strat.address // 策略
      );
    }

    // only LP token
    if (allocPoint.gt(0) && [ 10, 19, 30, 33 ].includes(i)) {
      const lpPair = new ethers.Contract(desire, MdexPair.interface, ethers.provider);
      const token0 = await lpPair.token0();
      const token1 = await lpPair.token1();

      // Temp: 留二个 lpToken 质押池
      const isAutoComp   = i < 30 ? true : false;
      const allocYPoint  = i < 30 ? 0 : 100;
      const allocUPoint  = i < 30 ? 0 : 100;
      const allocBPoint  = i < 30 ? 100 : 0;

      // create strategy
      const strat = await deploy('StratX', {
        from: governor,
        args: [
          router,
          yfPool.address,
          yToken.address,
          false,            // isErc20Token: 单币 = true, lp = false
          isAutoComp,       // isAutoComp: 自动复投
          hecoPool.address, // 源机枪池
          i,                // 源机枪池Id
          desire,           // deposit token
          token0,           // lp token0
          token1,           // lp token1
          earned            // 源机枪池平台币
        ]
      });

      // YF 回购保管地址
      await execute(
        'StratX',
        { from: governor },
        'setFundsAccount',
        boardroom,
        custodian
      );

      // add to YF pool
      await execute(
        'YFPool',
        { from: deployer },
        'add',
        true,         // _withUpdate
        allocYPoint,  // _allocYPoint
        allocUPoint,  // _allocUPoint
        allocBPoint,  // allocBPoint
        desire,       // deposit token
        isAutoComp ? earned : ethers.constants.AddressZero,
        strat.address // 策略
      );

      console.log('   add HecoPool(pid = %s, lpToken = %s) to YF %s Pool', i, desire, isAutoComp ? 'LP' : 'Deposit');
    }
  }

  console.log('4. YF Strategy has deployed');
  return network.live;
};

func.id = 'deploy_yf_strategy';
module.exports = func;
