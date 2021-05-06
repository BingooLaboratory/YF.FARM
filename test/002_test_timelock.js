const { expect } = require("chai");
const { get, execute } = deployments;

describe("Timelock Controller", () => {
  beforeEach(async () => {
    await deployments.fixture();
  });

  it("Should schedule set permission denied", async () => {
    const [ faker ] = await getUnnamedAccounts();
    const yPool = await get('YFPool');

    const options = { from: faker };
    const bytes32 = '0x' + Buffer.alloc(32).toString('hex');

    const result = await execute(
      'TimelockController',
      options,
      'scheduleSet',
      yPool.address,
      false,
      0,
      10,
      10,
      false,
      false,
      bytes32,
      bytes32
    ).catch(err => err);

    expect(result).to.be.an('Error');
  });

  it("Should schedule set success", async () => {
    const { governor } = await getNamedAccounts();
    const yPool = await get('YFPool');

    const options = { from: governor };
    const bytes32 = '0x' + Buffer.alloc(32).toString('hex');

    const { events } = await execute(
      'TimelockController',
      options,
      'scheduleSet',
      yPool.address,
      false,
      0,
      10,
      10,
      10,
      bytes32,
      bytes32
    ).catch(err => err);

    const [{ topics }] = events;
    expect(topics[0]).to.equal('0x6e982e26559a0a655c3896e2831eda508b0c9bc4396c04165121fe68137b1ef5');
  });
});
