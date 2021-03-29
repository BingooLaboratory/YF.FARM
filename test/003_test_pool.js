const { expect } = require("chai");
const { get, execute, read, getArtifact } = deployments;

describe("YF Pool", () => {
  // 有钱人
  const richer = '0xbB663e54106F61923b30c321210a9ff816Be4495';
  const fund10 = ethers.utils.parseUnits('10');
  const fund50 = ethers.utils.parseUnits('50');

  let sa, dev;
  let faker;
  let strategy;
  let hecoPool, router;

  function mineBlock() {
    return network.provider.request({ method: 'evm_mine', params: []});
  }

  function fromWei(n) {
    return ethers.utils.formatUnits(n);
  }

  beforeEach(async () => {
    await deployments.fixture();
    await network.provider.request({ method: "hardhat_impersonateAccount", params: [ richer ]});

    sa       = await ethers.getSigner(richer);
    dev      = await ethers.getNamedSigner('deployer');
    faker    = await ethers.getNamedSigner('boardroom');
    strategy = await get('StratX');

    const Router   = await getArtifact("MdexRouter");
    const HecoPool = await getArtifact("HecoPool");
    hecoPool = await ethers.getContractAt(HecoPool.abi, '0xFB03e11D93632D97a8981158A632Dd5986F5E909');
    router   = await ethers.getContractAt(Router.abi, '0xED7d5F38C79115ca12fe6C0041abb22F0A06C300', dev);

    // create WHT-YF pair
    const { deployer } = await getNamedAccounts();
    const deadline = Math.ceil((+Date.now())/1000) + 60;
    const yToken = await ethers.getContract('YFToken');

    await execute('YFToken', { from: deployer }, 'mint', deployer, fund50);
    await yToken.approve(router.address, fund50);

    // create WHT-KT pair
    await router.addLiquidityETH(
      yToken.address,
      fund50,
      0,
      0,
      deployer,
      deadline,
      { value: fund50 }
    ).then(tx => tx.wait());
  });

  it("Should deposit Single-Token spell to LP", async () => {
    const [ creator ] = await getUnnamedAccounts();
    const options = { from: creator, value:  fund10 };

    const mdx_wht = await read('YFPool', 'poolInfo', 1);
    const strat = await ethers.getContractAt(strategy.abi, mdx_wht.strat);

    // 单币 -> LP
    const interface = new ethers.utils.Interface(strategy.abi);
    const amount = interface.encodeFunctionData('addLiquidityWERC20', [[ 0, 0, 0, 0, 0 ]]);
    await execute('YFPool', options, 'execute', 1, amount);

    const wantLockedTotal = await strat.wantLockedTotal().then(n => fromWei(n));
    const sharesTotal     = await strat.sharesTotal().then(n => fromWei(n));
    const userShares      = await read('YFPool', 'userInfo', 1, creator).then(({ shares }) => fromWei(shares));
    const hecoShares      = await hecoPool.userInfo(19, mdx_wht.strat).then(({ amount }) => fromWei(amount));

    expect(userShares).to.equal(sharesTotal);
    expect(sharesTotal).to.equal(wantLockedTotal);
    expect(hecoShares).to.equal(userShares);
  });

  it("Should withdraw LP split to Single-Token", async () => {
    const [ creator ] = await getUnnamedAccounts();
    const options = { from: creator, value:  fund10 };

    const mdx_wht = await read('YFPool', 'poolInfo', 1);
    const strat = await ethers.getContractAt(strategy.abi, mdx_wht.strat);

    // 单币 -> LP
    const interface = new ethers.utils.Interface(strategy.abi);
    const calldata = interface.encodeFunctionData('addLiquidityWERC20', [[ 0, 0, 0, 0, 0 ]]);

    // 1. deposit
    await execute('YFPool', options, 'execute', 1, calldata);

    // 2. withdraw
    const lp = await hecoPool.userInfo(19, mdx_wht.strat);
    await execute('YFPool', { from: creator }, 'withdraw', 1, lp.amount);

    // 3. withdraw 0.02% 手续费
    const wantLockedTotal = await strat.wantLockedTotal().then(n => fromWei(n));
    const sharesTotal     = await strat.sharesTotal().then(n => fromWei(n));
    const userShares      = await read('YFPool', 'userInfo', 1, creator).then(({ shares }) => fromWei(shares));
    const hecoShares      = await hecoPool.userInfo(19, mdx_wht.strat).then(({ amount }) => fromWei(amount));

    expect(userShares).to.equal(sharesTotal);
    expect(sharesTotal).to.equal(wantLockedTotal);
    expect(hecoShares).to.equal(userShares);
    expect(userShares).to.equal('0.0');
  });

  it("Should autocomp success", async () => {
    const [ creator ] = await getUnnamedAccounts();
    const { governor } = await ethers.getNamedSigner('governor');

    const options = { from: creator, value: fund10 };
    const yToken = await get('YFToken');
    const yPool = await ethers.getContract('YFPool', sa);

    const husd_usdt = await read('YFPool', 'poolInfo', 0);
    const mdx_wht   = await read('YFPool', 'poolInfo', 1);

    const strat0 = await ethers.getContractAt(strategy.abi, husd_usdt.strat, governor);
    const strat1 = await ethers.getContractAt(strategy.abi, mdx_wht.strat, governor);

    // 单币 -> LP
    const usdAmount = ethers.utils.parseUnits('10', 8);
    const interface = new ethers.utils.Interface(strategy.abi);
    const calldata0 = interface.encodeFunctionData('addLiquidityWERC20', [[ usdAmount, 0, 0, 0, 0 ]]);
    const calldata1 = interface.encodeFunctionData('addLiquidityWERC20', [[ 0, 0, 0, 0, 0 ]]);

    // 1. deposit HUSD
    const husd = await ethers.getContractAt(yToken.abi, '0x0298c2b32eaE4da002a15f36fdf7615BEa3DA047', sa);
    await husd.approve(yPool.address, usdAmount);
    await yPool.execute(0, calldata0);

    // 2. deposit HT
    await execute('YFPool', options, 'execute', 1, calldata1);

    await mineBlock();
    await mineBlock();
    await mineBlock();

    // 3. autocomp
    await strat0.earn();
    await strat1.earn();

    await mineBlock();
    await mineBlock();
  });
});
