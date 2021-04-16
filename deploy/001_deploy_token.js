const func = async ({ getNamedAccounts, deployments, network }) => {
  const { deploy, execute } = deployments;
  const { deployer, governor } = await getNamedAccounts();

  // YF Token
  await deploy('YFToken', { from: deployer });

  // NOTICE: 上线时要确认分配
  await execute('YFToken', { from: deployer }, 'mint', governor, ethers.utils.parseUnits('500'));

  console.log('1. YF Token has deployed');
  return network.live;
};

func.id = 'deploy_yf_token';
module.exports = func;
