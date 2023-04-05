// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import "forge-std/Test.sol";

import "src/library/FixedPointArithmetic.sol";
import "src/transaction-allocator/common/TAStructs.sol";
import "src/paymaster/Paymaster.sol";
import "../modules/ITransactionAllocatorDebug.sol";
import "script/TA.Deployment.s.sol";
import "src/library/Transaction.sol";

abstract contract TATestBase is Test {
    using FixedPointTypeHelper for FixedPointType;
    using TransactionLib for Transaction;
    using ECDSA for bytes32;

    string constant mnemonic = "test test test test test test test test test test test junk";
    uint256 constant relayerCount = 10;
    uint256 constant relayerAccountsPerRelayer = 10;
    uint256 constant delegatorCount = 10;
    uint256 constant userCount = 10;
    uint256 constant initialMainAccountFunds = MINIMUM_STAKE_AMOUNT + 10 ether;
    uint256 constant initialRelayerAccountFunds = 1 ether;
    uint256 constant initialDelegatorFunds = 1 ether;
    uint256 constant initialUserAccountFunds = 1 ether;

    TokenAddress[] internal supportedTokens;
    InitalizerParams deployParams = InitalizerParams({
        blocksPerWindow: 10,
        relayersPerWindow: 10,
        penaltyDelayBlocks: 10,
        bondTokenAddress: TokenAddress.wrap(address(0)),
        supportedTokens: supportedTokens
    });

    ITransactionAllocatorDebug internal ta;
    Paymaster internal paymaster;

    uint256[] internal relayerMainKey;
    RelayerAddress[] internal relayerMainAddress;
    mapping(RelayerAddress => RelayerAccountAddress[]) internal relayerAccountAddresses;
    mapping(RelayerAddress => uint256[]) internal relayerAccountKeys;
    uint256[] internal delegatorKeys;
    DelegatorAddress[] internal delegatorAddresses;
    address[] userAddresses;
    mapping(address => uint256) internal userKeys;

    ERC20 bico;

    uint256 private _postDeploymentSnapshotId = type(uint256).max;

    function setUp() public virtual {
        if (_postDeploymentSnapshotId != type(uint256).max) {
            return;
        }

        // Deploy the bico token
        bico = new ERC20("BICO", "BICO");
        vm.label(address(bico), "ERC20(BICO)");
        supportedTokens.push(TokenAddress.wrap(address(bico)));
        supportedTokens.push(NATIVE_TOKEN);
        deployParams.bondTokenAddress = TokenAddress.wrap(address(bico));
        deployParams.supportedTokens = supportedTokens;

        uint32 keyIndex = 0;

        // Deploy TA, requires --ffi
        TADeploymentScript script = new TADeploymentScript();
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, ++keyIndex);
        ta = script.deployWithDebugModule(deployerPrivateKey, deployParams, false);

        // Deploy Paymaster
        paymaster = new Paymaster(address(ta));

        // Generate Relayer Addresses
        for (uint256 i = 0; i < relayerCount; i++) {
            // Generate Main Relayer Addresses
            relayerMainKey.push(vm.deriveKey(mnemonic, ++keyIndex));
            relayerMainAddress.push(RelayerAddress.wrap(vm.addr(relayerMainKey[i])));
            deal(RelayerAddress.unwrap(relayerMainAddress[i]), initialMainAccountFunds);
            deal(address(bico), RelayerAddress.unwrap(relayerMainAddress[i]), initialMainAccountFunds);
            vm.label(RelayerAddress.unwrap(relayerMainAddress[i]), _stringConcat2("relayer", vm.toString(i)));

            // Generate Relayer Account Addresses
            for (uint256 j = 0; j < relayerAccountsPerRelayer; j++) {
                relayerAccountKeys[relayerMainAddress[i]].push(vm.deriveKey(mnemonic, ++keyIndex));
                relayerAccountAddresses[relayerMainAddress[i]].push(
                    RelayerAccountAddress.wrap(vm.addr(relayerAccountKeys[relayerMainAddress[i]][j]))
                );
                deal(
                    RelayerAccountAddress.unwrap(relayerAccountAddresses[relayerMainAddress[i]][j]),
                    initialRelayerAccountFunds
                );
                deal(
                    address(bico),
                    RelayerAccountAddress.unwrap(relayerAccountAddresses[relayerMainAddress[i]][j]),
                    initialRelayerAccountFunds
                );
                vm.label(
                    RelayerAccountAddress.unwrap(relayerAccountAddresses[relayerMainAddress[i]][j]),
                    _stringConcat4("relayer", vm.toString(i), "account", vm.toString(j))
                );
            }
        }

        // Generate Delegator Addresses
        for (uint256 i = 0; i < delegatorCount; i++) {
            delegatorKeys.push(vm.deriveKey(mnemonic, ++keyIndex));
            delegatorAddresses.push(DelegatorAddress.wrap(vm.addr(delegatorKeys[i])));
            deal(DelegatorAddress.unwrap(delegatorAddresses[i]), initialDelegatorFunds);
            deal(address(bico), DelegatorAddress.unwrap(delegatorAddresses[i]), initialDelegatorFunds);
            vm.label(DelegatorAddress.unwrap(delegatorAddresses[i]), _stringConcat2("delegator", vm.toString(i)));
        }

        // Generate User Addresses
        for (uint256 i = 0; i < userCount; i++) {
            uint256 key = vm.deriveKey(mnemonic, ++keyIndex);
            userAddresses.push(vm.addr(key));
            userKeys[userAddresses[i]] = key;
            deal(userAddresses[i], initialUserAccountFunds);
            vm.label(userAddresses[i], _stringConcat2("user", vm.toString(i)));
        }

        _postDeploymentSnapshotId = vm.snapshot();
    }

    modifier atSnapshot() {
        bool revertStatus = vm.revertTo(_preTestSnapshotId());
        if (!revertStatus) {
            fail("Failed to revert to post deployment snapshot");
        }
        _;
    }

    function _stringConcat2(string memory a, string memory b) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b));
    }

    function _stringConcat3(string memory a, string memory b, string memory c) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b, c));
    }

    function _stringConcat4(string memory a, string memory b, string memory c, string memory d)
        internal
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(a, b, c, d));
    }

    function _preTestSnapshotId() internal view virtual returns (uint256) {
        return _postDeploymentSnapshotId;
    }

    function _startPrankRA(RelayerAddress _relayer) internal {
        vm.startPrank(RelayerAddress.unwrap(_relayer));
    }

    function _startPrankRAA(RelayerAccountAddress _account) internal {
        vm.startPrank(RelayerAccountAddress.unwrap(_account));
    }

    function _prankDa(DelegatorAddress _da) internal {
        vm.prank(DelegatorAddress.unwrap(_da));
    }

    function _assertEqFp(FixedPointType _a, FixedPointType _b) internal {
        assertEq(_a.toUint256(), _b.toUint256());
    }

    function _assertEqRa(RelayerAddress _a, RelayerAddress _b) internal {
        assertEq(RelayerAddress.unwrap(_a), RelayerAddress.unwrap(_b));
    }

    function _signTransaction(uint256 _key, Transaction memory _tx)
        internal
        pure
        returns (Transaction memory _txSigned)
    {
        _txSigned = _tx;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, _tx.hashMemory().toEthSignedMessageHash());
        _txSigned.signature = abi.encodePacked(r, s, v);
    }

    // add this to be excluded from coverage report
    function test() public {}
}