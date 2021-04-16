require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-etherscan");
require("hardhat-deploy");
require("hardhat-deploy-ethers");

task("accounts", "Prints the list of accounts", async () => {
  const accounts = await ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

task("yfpool", "Prints the info of YF pool", async () => {
  const Pair    = await ethers.getContractFactory("contracts/mock/MockMdexPair.sol:MdexPair");
  const YFToken = await ethers.getContractFactory("YFToken");
  const YFPool  = await ethers.getContractFactory("YFPool");
  const StratX  = await ethers.getContractFactory("StratX");

  const yPool = new ethers.Contract('0x78117e80A887e03C1F57B0975bC9a798Cc29eeF7', YFPool.interface, ethers.provider);
  const poolLength = await yPool.poolLength().then(n => n.toNumber());

  for (let i = 0; i < poolLength; i++) {
    const poolInfo = await yPool.poolInfo(i);
    const pair  = new ethers.Contract(poolInfo.want, Pair.interface, ethers.provider);
    const strat = new ethers.Contract(poolInfo.strat, StratX.interface, ethers.provider);

    if (await strat.isErc20Token()) {
      const symbol = await (new ethers.Contract(poolInfo.want, YFToken.interface, ethers.provider)).symbol();
      console.log('pid = %s, want = %s, symbol = %s', i, poolInfo.want, symbol);
    } else {
      const token0 = await pair.token0();
      const token1 = await pair.token1();

      const symbol0 = await (new ethers.Contract(token0, YFToken.interface, ethers.provider)).symbol();
      const symbol1 = await (new ethers.Contract(token1, YFToken.interface, ethers.provider)).symbol();

      console.log('\n\n   pid = %s, want = %s', i, poolInfo.want);
      console.log('token0 = %s symbol0 = %s', token0, symbol0);
      console.log('token1 = %s symbol1 = %s', token1, symbol1);
    }
  }
});

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
 module.exports = {
  namedAccounts: {
    deployer: {
      default: 0,
    },
    governor: {
      default: 1,
    },
    custodian: {
      default: 2,
    },
    boardroom: {
      default: 3,
    },
    team1: {
      default: 4,
    },
    team2: {
      default: 5
    },
  },
  networks: {
    hardhat: {
      gas: 'auto',
      gasPrice: 'auto',
      forking: {
        url: 'https://http-mainnet-node.huobichain.com',
        enabled: true
      },
    },
    debug: {
      url: 'http://127.0.0.1:8545',
      timeout: 1200000
    },
    bsc: {
      url: 'https://bsc-dataseed1.ninicoin.io'
    },
    heco: {
      accounts: {
        mnemonic: "test test test"
      },
      chainId: 128,
      gasMultiplier: 1.25,
      gas: 'auto',
      gasPrice: 'auto',
      url: 'https://http-mainnet-node.huobichain.com',
    },
    okex: {
      url: 'https://exchaintest.okexcn.com'
    }
  },
  solidity: {
    compilers: [{
      version: "0.6.12",
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        }
      }
    }, {
      version: "0.6.6",
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        }
      }
    }, {
      version: "0.5.16",
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        }
      }
    }],
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  mocha: {
    timeout: 1200000
  }
};
