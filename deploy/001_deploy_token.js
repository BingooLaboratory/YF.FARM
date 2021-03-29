const func = async ({ getNamedAccounts, deployments, network }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  // YF Token
  await deploy('YFToken', { from: deployer });

  console.log('1. YF Token has deployed');
  return network.live;
};

func.id = 'deploy_yf_token';
module.exports = func;
