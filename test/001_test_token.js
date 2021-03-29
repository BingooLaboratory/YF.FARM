const { expect } = require("chai");
const { execute } = deployments;

describe("YF Vaults Token", () => {
  beforeEach(async () => {
    await deployments.fixture();
  });

  it("Should mint permission denied", async () => {
    const [ faker ] = await getUnnamedAccounts();
    const options = { from: faker };

    const result = await execute('YFToken', options, 'mint', faker, 1).catch(err => err);
    expect(result).to.be.an('Error');
  });

  it("Should mint is 500 YF", async () => {
    const { deployer } = await getNamedAccounts();
    const [ faker ] = await getUnnamedAccounts();

    const options = { from: deployer };
    const yToken = await ethers.getContract('YFToken');

    await execute('YFToken', options, 'mint', faker, ethers.utils.parseUnits('500'));
    const balance = await yToken.balanceOf(faker);

    expect(balance).to.equal(ethers.utils.parseUnits('500'));
  });
});
