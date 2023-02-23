import { ethers } from 'ethers';
import { AbiCoder } from 'ethers/lib/utils';
import path from 'path/posix';

const args = process.argv.slice(2);

if (args.length != 1) {
  console.log(`please supply the correct parameters:
    moduleName
  `);
  process.exit(1);
}

const printSelectors = async (
  contractName: string,
  artifactFolderPath = path.join(__dirname, '../out')
) => {
  const contractFilePath = path.join(
    artifactFolderPath,
    `${contractName}.sol`,
    `${contractName}.json`
  );
  const contractArtifact = require(contractFilePath);
  const abi = contractArtifact.abi;
  const bytecode = contractArtifact.bytecode;
  const target = new ethers.ContractFactory(abi, bytecode);
  const signatures = Object.keys(target.interface.functions);

  const selectors = signatures.reduce((acc: string[], val: string) => {
    acc.push(target.interface.getSighash(val));
    return acc;
  }, []);

  const coded = new AbiCoder().encode(['bytes4[]'], [selectors]);

  process.stdout.write(coded);
};

printSelectors(args[0], args[1])
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
