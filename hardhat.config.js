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
      chainId: 128,
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
