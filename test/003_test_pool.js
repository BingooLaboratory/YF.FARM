const { expect } = require("chai");
const { get, execute, read, getArtifact } = deployments;

describe("YF Pool", () => {
  // 有钱人
  const richer = '0xbB663e54106F61923b30c321210a9ff816Be4495';
  const fund100 = ethers.utils.parseUnits('100');
  const fund500 = ethers.utils.parseUnits('500');

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

    await execute('YFToken', { from: deployer }, 'mint', deployer, fund500);
    await yToken.approve(router.address, fund500);

    // create WHT-KT pair
    await router.addLiquidityETH(
      yToken.address,
      fund500,
      0,
      0,
      deployer,
      deadline,
      { value: fund500 }
    ).then(tx => tx.wait());
  });

  it("Should deposit Single-Token spell to LP", async () => {
    const { custodian } = await getNamedAccounts();
    const [ creator ] = await getUnnamedAccounts();
    const options = { from: creator, value:  fund100 };

    const mdx_wht = await read('YFPool', 'poolInfo', 3);
    const strat = await ethers.getContractAt(strategy.abi, mdx_wht.strat);

    // 单币 -> LP
    const interface = new ethers.utils.Interface(strategy.abi);
    const amount = interface.encodeFunctionData('addLiquidityWERC20', [[ 0, 0, 0, 0, 0 ]]);
    await execute('YFPool', options, 'execute', 3, amount);

    const wantLockedTotal = await strat.wantLockedTotal().then(n => fromWei(n));
    const sharesTotal     = await strat.sharesTotal().then(n => fromWei(n));
    const userShares      = await read('YFPool', 'userInfo', 3, creator).then(({ shares }) => fromWei(shares));
    const hecoShares      = await hecoPool.userInfo(19, mdx_wht.strat).then(({ amount }) => fromWei(amount));

    expect(userShares).to.equal(sharesTotal);
    expect(sharesTotal).to.equal(wantLockedTotal);
    expect(hecoShares).to.equal(userShares);

    // Harvest SwapMining Reward
    const mdx = await ethers.getContractAt('YFToken', '0x25D2e80cB6B86881Fd7e07dd263Fb79f4AbE033c');
    await strat.harvestSwapMiningReward();
    const reward = await mdx.balanceOf(custodian);
    expect(reward).to.gt(0);
  });

  it("Should withdraw LP split to Single-Token", async () => {
    const [ creator ] = await getUnnamedAccounts();
    const options = { from: creator, value:  fund100 };

    const mdx_wht = await read('YFPool', 'poolInfo', 3);
    const strat = await ethers.getContractAt(strategy.abi, mdx_wht.strat);

    // 单币 -> LP
    const interface = new ethers.utils.Interface(strategy.abi);
    const calldata = interface.encodeFunctionData('addLiquidityWERC20', [[ 0, 0, 0, 0, 0 ]]);

    // 1. deposit
    await execute('YFPool', options, 'execute', 3, calldata);

    // 2. withdraw
    const lp = await hecoPool.userInfo(19, mdx_wht.strat);
    await execute('YFPool', { from: creator }, 'withdraw', 3, lp.amount);

    // 3. withdraw 0.02% 手续费
    const wantLockedTotal = await strat.wantLockedTotal().then(n => fromWei(n));
    const sharesTotal     = await strat.sharesTotal().then(n => fromWei(n));
    const userShares      = await read('YFPool', 'userInfo', 3, creator).then(({ shares }) => fromWei(shares));
    const hecoShares      = await hecoPool.userInfo(19, mdx_wht.strat).then(({ amount }) => fromWei(amount));

    expect(userShares).to.equal(sharesTotal);
    expect(sharesTotal).to.equal(wantLockedTotal);
    expect(hecoShares).to.equal(userShares);
    expect(userShares).to.equal('0.0');
  });

  it("Should autocomp success", async () => {
    const [ creator ] = await getUnnamedAccounts();
    const { governor } = await ethers.getNamedSigner('governor');

    const options = { from: creator, value: fund100 };
    const yToken = await get('YFToken');
    const yPool = await ethers.getContract('YFPool', sa);

    const husd_usdt = await read('YFPool', 'poolInfo', 2);
    const mdx_wht   = await read('YFPool', 'poolInfo', 3);

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
    await yPool.execute(2, calldata0);

    // 2. deposit HT
    await execute('YFPool', options, 'execute', 3, calldata1);

    await mineBlock();
    await mineBlock();

    // 3. autocomp
    await strat0.earn();
    await strat1.earn();

    await mineBlock();
    await mineBlock();
  });

  it("Should Single-Token spell LP to Staked", async () => {
    const [ creator ] = await getUnnamedAccounts();
    const options = { from: creator, value:  fund100 };

    const wht_eth = await read('YFPool', 'poolInfo', 4);
    const strat = await ethers.getContractAt(strategy.abi, wht_eth.strat);

    // 单币 -> LP
    const interface = new ethers.utils.Interface(strategy.abi);
    const amount = interface.encodeFunctionData('addLiquidityWERC20', [[ 0, 0, 0, 0, 0 ]]);
    await execute('YFPool', options, 'execute', 4, amount);

    const wantLockedTotal = await strat.wantLockedTotal().then(n => fromWei(n));
    const sharesTotal     = await strat.sharesTotal().then(n => fromWei(n));
    const userShares      = await read('YFPool', 'userInfo', 4, creator).then(({ shares }) => fromWei(shares));
    const hecoShares      = await hecoPool.userInfo(30, wht_eth.strat).then(({ amount }) => fromWei(amount));

    expect(userShares).to.equal(sharesTotal);
    expect(sharesTotal).to.equal(wantLockedTotal);
    expect(hecoShares).to.equal('0.0');
  });

  it("Should withdraw staked LP split to Single-Token", async () => {
    const [ creator ] = await getUnnamedAccounts();
    const options = { from: creator, value:  fund100 };

    const wht_eth = await read('YFPool', 'poolInfo', 4);
    const strat = await ethers.getContractAt(strategy.abi, wht_eth.strat);

    // 单币 -> LP
    const interface = new ethers.utils.Interface(strategy.abi);
    const calldata = interface.encodeFunctionData('addLiquidityWERC20', [[ 0, 0, 0, 0, 0 ]]);

    // 1. deposit
    await execute('YFPool', options, 'execute', 4, calldata);

    // 2. withdraw
    const lp = await read('YFPool', 'userInfo', 4, creator);
    await execute('YFPool', { from: creator }, 'withdraw', 4, lp.shares);

    // 3. withdraw 0.02% 手续费
    const wantLockedTotal = await strat.wantLockedTotal().then(n => fromWei(n));
    const sharesTotal     = await strat.sharesTotal().then(n => fromWei(n));
    const userShares      = await read('YFPool', 'userInfo', 4, creator).then(({ shares }) => fromWei(shares));
    const hecoShares      = await hecoPool.userInfo(30, wht_eth.strat).then(({ amount }) => fromWei(amount));;

    expect(userShares).to.equal(sharesTotal);
    expect(sharesTotal).to.equal(wantLockedTotal);
    expect(hecoShares).to.equal('0.0');
    expect(userShares).to.equal('0.0');
  });

  it("Should deposit & withdraw Single-Token to autocomp", async () => {
    const { governor } = await ethers.getNamedSigner('governor');
    const yToken = await get('YFToken');
    const yPool = await ethers.getContract('YFPool', sa);

    const pool = await read('YFPool', 'poolInfo', 0);
    const strat = await ethers.getContractAt(strategy.abi, pool.strat);

    // 1. deposit HBTC
    const hbtc = await ethers.getContractAt(yToken.abi, '0x66a79D23E58475D2738179Ca52cd0b41d73f0BEa', sa);
    await hbtc.approve(yPool.address, ethers.utils.parseUnits('0.005'));
    await yPool.deposit(0, ethers.utils.parseUnits('0.005'));

    let wantLockedTotal = await strat.wantLockedTotal().then(n => fromWei(n));
    let sharesTotal     = await strat.sharesTotal().then(n => fromWei(n));
    let userShares      = await read('YFPool', 'userInfo', 0, richer).then(({ shares }) => fromWei(shares));
    let hecoShares      = await hecoPool.userInfo(1, pool.strat).then(({ amount }) => fromWei(amount));

    expect(userShares).to.equal(sharesTotal);
    expect(sharesTotal).to.equal(wantLockedTotal);
    expect(hecoShares).to.equal(userShares);

    // 2. autocomp
    const strat0 = await ethers.getContractAt(strategy.abi, pool.strat, governor);
    await mineBlock();
    await strat0.earn();
    await mineBlock();

    // 3. withdraw HBTC
    userShares = await read('YFPool', 'userInfo', 0, richer);
    await yPool.withdraw(0, userShares.shares);

    wantLockedTotal = await strat.wantLockedTotal().then(n => fromWei(n));
    sharesTotal     = await strat.sharesTotal().then(n => fromWei(n));
    userShares      = await read('YFPool', 'userInfo', 0, richer).then(({ shares }) => fromWei(shares));
    hecoShares      = await hecoPool.userInfo(1, pool.strat).then(({ amount }) => fromWei(amount));

    expect(userShares).to.equal(sharesTotal);
    expect(sharesTotal).to.equal(wantLockedTotal);
    expect(hecoShares).to.equal('0.0');
    expect(userShares).to.equal('0.0');
  });

  it("Should deposit & withdraw Single-Token to staked only", async () => {
    const { governor } = await ethers.getNamedSigner('governor');
    const yToken = await get('YFToken');
    const yPool = await ethers.getContract('YFPool', sa);

    const pool = await read('YFPool', 'poolInfo', 1);
    const strat = await ethers.getContractAt(strategy.abi, pool.strat);

    // 1. deposit HUSD
    const husd = await ethers.getContractAt(yToken.abi, '0x0298c2b32eaE4da002a15f36fdf7615BEa3DA047', sa);
    await husd.approve(yPool.address, ethers.utils.parseUnits('100', 8));
    await yPool.deposit(1, ethers.utils.parseUnits('100', 8));

    let wantLockedTotal = await strat.wantLockedTotal().then(n => fromWei(n));
    let sharesTotal     = await strat.sharesTotal().then(n => fromWei(n));
    let userShares      = await read('YFPool', 'userInfo', 1, richer).then(({ shares }) => fromWei(shares));
    let hecoShares      = await hecoPool.userInfo(2, pool.strat).then(({ amount }) => fromWei(amount));

    expect(userShares).to.equal(sharesTotal);
    expect(sharesTotal).to.equal(wantLockedTotal);
    expect(hecoShares).to.equal('0.0');

    // 2. withdraw HUSD
    userShares = await read('YFPool', 'userInfo', 1, richer);
    await yPool.withdraw(1, userShares.shares);

    wantLockedTotal = await strat.wantLockedTotal().then(n => fromWei(n));
    sharesTotal     = await strat.sharesTotal().then(n => fromWei(n));
    userShares      = await read('YFPool', 'userInfo', 1, richer).then(({ shares }) => fromWei(shares));
    hecoShares      = await hecoPool.userInfo(2, pool.strat).then(({ amount }) => fromWei(amount));

    expect(userShares).to.equal(sharesTotal);
    expect(sharesTotal).to.equal(wantLockedTotal);
    expect(hecoShares).to.equal('0.0');
    expect(userShares).to.equal('0.0');
  });

  it("Should user only withdraw capitals success", async () => {
    const [ creator ] = await getUnnamedAccounts();
    const { governor } = await ethers.getNamedSigner('governor');

    const options = { from: creator, value: fund100 };
    const mdx_wht = await read('YFPool', 'poolInfo', 3);
    const strat0  = await ethers.getContractAt(strategy.abi, mdx_wht.strat, governor);

    // 单币 -> LP
    const interface = new ethers.utils.Interface(strategy.abi);
    const calldata0 = interface.encodeFunctionData('addLiquidityWERC20', [[ 0, 0, 0, 0, 0 ]]);

    let total, capitals, tmp;

    // 1. deposit HT
    await execute('YFPool', options, 'execute', 3, calldata0);
    [ total, capitals ] = await read('YFPool', 'stakedWantTokens', 3, creator);
    expect(total).to.equal(capitals);

    // 2. autocomp
    await mineBlock();
    await mineBlock();
    await strat0.earn();
    await mineBlock();
    await mineBlock();

    // 3. withdraw captials
    await execute('YFPool', { from: creator }, 'withdraw', 3, capitals);
    [, capitals ] = await read('YFPool', 'stakedWantTokens', 3, creator);
    expect(fromWei(capitals)).to.equal('0.0');

    // 4. deposit HT twice
    await execute('YFPool', options, 'execute', 3, calldata0);
    await execute('YFPool', options, 'execute', 3, calldata0);
    [, tmp ] = await read('YFPool', 'stakedWantTokens', 3, creator);

    // 5. half withdraw
    await execute('YFPool', { from: creator }, 'withdraw', 3, fund100);
    [ total, capitals ] = await read('YFPool', 'stakedWantTokens', 3, creator);
    expect(total).to.above(capitals);
    expect(tmp.sub(fund100)).to.equal(capitals);
  });
});
