const func = async ({ getNamedAccounts, deployments, network }) => {
  const { deploy } = deployments;
  const { deployer, governor } = await getNamedAccounts();

  await deploy('TimelockController', { from: deployer, args: [ governor ]});
  console.log('2. TimelockController has deployed');

  return network.live;
};

func.id = 'deploy_timelock_controller';

module.exports = func;
