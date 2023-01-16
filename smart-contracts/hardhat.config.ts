import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import '@tenderly/hardhat-tenderly';
import 'hardhat-contract-sizer';
import * as dotenv from 'dotenv';

dotenv.config();

// Fix tenderly export issue
(BigInt.prototype as any).toJSON = function () {
  return this.toString();
};

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: '0.8.13',
        settings: {
          outputSelection: {
            '*': {
              '*': ['storageLayout'],
            },
          },
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
        },
      },
    ],
  },
  networks: {
    goerli: {
      url: process.env.GOERLI_URL || '',
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
  gasReporter: {
    enabled: true,
    currency: 'USD',
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: true,
  },
};

export default config;
