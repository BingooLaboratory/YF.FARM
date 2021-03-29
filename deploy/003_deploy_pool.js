const func = async ({ getNamedAccounts, deployments, network }) => {
  const { deploy, get, execute } = deployments;
  const { deployer } = await getNamedAccounts();

  const options = {
    from: deployer
  };

  const yToken = await get('YFToken');
  const yfPool = await deploy('YFPool', { ...options, args: [ yToken.address ]});

  // Change yToken Owner
  if (network.live) {
    await execute('YFToken', options, 'transferOwnership', yfPool.address);
  }

  console.log('3. YFPool pool has deployed');
  return network.live;
};

func.id = 'deploy_pool';
module.exports = func;
