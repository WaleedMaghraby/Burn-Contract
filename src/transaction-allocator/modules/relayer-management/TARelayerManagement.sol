// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ITARelayerManagement.sol";
import "../delegation/interfaces/ITADelegation.sol";
import "./TARelayerManagementStorage.sol";
import "../transaction-allocation/TATransactionAllocationStorage.sol";
import "../../common/TAHelpers.sol";
import "../../common/TAConstants.sol";

import "forge-std/console2.sol";

contract TARelayerManagement is
    ITARelayerManagement,
    TARelayerManagementStorage,
    TAHelpers,
    TATransactionAllocationStorage
{
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    function _verifyPrevCdfHash(uint16[] calldata _array, uint256 _windowId, uint256 _cdfLogIndex)
        internal
        view
        returns (bool)
    {
        // Validate _cdfLogIndex
        RMStorage storage ds = getRMStorage();
        if (
            !(
                ds.cdfHashUpdateLog[_cdfLogIndex].windowId <= _windowId
                    && (
                        _cdfLogIndex == ds.cdfHashUpdateLog.length - 1
                            || ds.cdfHashUpdateLog[_cdfLogIndex + 1].windowId > _windowId
                    )
            )
        ) {
            return false;
        }

        return ds.cdfHashUpdateLog[_cdfLogIndex].cdfHash == keccak256(abi.encodePacked(_array));
    }

    function _scaleStake(uint256 _stake) internal pure returns (uint32) {
        return (_stake / STAKE_SCALING_FACTOR).toUint32();
    }

    function _addNewRelayerToDelegationArray(uint32[] calldata _delegationArray)
        internal
        pure
        returns (uint32[] memory)
    {
        uint256 delegationArrayLength = _delegationArray.length;
        uint32[] memory newDelegationArrayLength = new uint32[](delegationArrayLength + 1);

        // TODO: can this be optimized using calldatacopy?
        for (uint256 i = 0; i < delegationArrayLength;) {
            newDelegationArrayLength[i] = _delegationArray[i];
            unchecked {
                ++i;
            }
        }
        newDelegationArrayLength[delegationArrayLength] = 0;

        return newDelegationArrayLength;
    }

    function _addNewRelayerToStakeArray(uint32[] calldata _stakeArray, uint256 _stake)
        internal
        pure
        returns (uint32[] memory)
    {
        uint256 stakeArrayLength = _stakeArray.length;
        uint32[] memory newStakeArray = new uint32[](stakeArrayLength + 1);

        // TODO: can this be optimized using calldatacopy?
        for (uint256 i = 0; i < stakeArrayLength;) {
            newStakeArray[i] = _stakeArray[i];
            unchecked {
                ++i;
            }
        }
        newStakeArray[stakeArrayLength] = _scaleStake(_stake);

        return newStakeArray;
    }

    function _removeRelayerFromStakeArray(uint32[] calldata _stakeArray, uint256 _index)
        internal
        pure
        returns (uint32[] memory)
    {
        uint256 newStakeArrayLength = _stakeArray.length - 1;
        uint32[] memory newStakeArray = new uint32[](newStakeArrayLength);

        for (uint256 i = 0; i < newStakeArrayLength;) {
            if (i == _index) {
                // Remove the node's stake from the array by substituting it with the last element
                newStakeArray[i] = _stakeArray[newStakeArrayLength];
            } else {
                newStakeArray[i] = _stakeArray[i];
            }
            unchecked {
                ++i;
            }
        }

        return newStakeArray;
    }

    function _removeRelayerFromDelegationArray(uint32[] calldata _delegationArray, uint256 _index)
        internal
        pure
        returns (uint32[] memory)
    {
        uint256 newDelegationArrayLength = _delegationArray.length - 1;
        uint32[] memory newDelegationArray = new uint32[](newDelegationArrayLength);

        for (uint256 i = 0; i < newDelegationArrayLength;) {
            if (i == _index) {
                // Remove the node's stake from the array by substituting it with the last element
                newDelegationArray[i] = _delegationArray[newDelegationArrayLength];
            } else {
                newDelegationArray[i] = _delegationArray[i];
            }
            unchecked {
                ++i;
            }
        }

        return newDelegationArray;
    }

    function _decreaseRelayerStakeInStakeArray(uint32[] calldata _stakeArray, uint256 _index, uint32 _scaledAmount)
        internal
        pure
        returns (uint32[] memory)
    {
        uint32[] memory newStakeArray = _stakeArray;
        newStakeArray[_index] = newStakeArray[_index] - _scaledAmount;
        return newStakeArray;
    }

    // TODO: Cooldown before relayer is allowed to transact
    // TODO: Implement a way to increase the relayer's stake
    /// @notice register a relayer
    /// @param _previousStakeArray current stake array for verification
    /// @param _stake amount to be staked
    /// @param _accounts list of accounts that the relayer will use for forwarding tx
    /// @param _endpoint that can be used by any app to send transactions to this relayer
    function register(
        uint32[] calldata _previousStakeArray,
        uint32[] calldata _currentDelegationArray,
        uint256 _stake,
        RelayerAccountAddress[] calldata _accounts,
        string memory _endpoint
    )
        external
        override
        verifyStakeArrayHash(_previousStakeArray)
        verifyDelegationArrayHash(_currentDelegationArray)
        returns (RelayerId)
    {
        RMStorage storage ds = getRMStorage();

        if (_accounts.length == 0) {
            revert NoAccountsProvided();
        }
        if (_stake < MINIMUM_STAKE_AMOUNT) {
            revert InsufficientStake(_stake, MINIMUM_STAKE_AMOUNT);
        }

        ds.bondToken.safeTransferFrom(msg.sender, address(this), _stake);

        RelayerId relayerId = _generateNewRelayerId(RelayerAddress.wrap(msg.sender));
        RelayerInfo storage node = ds.relayerInfo[relayerId];
        node.relayerAddress = RelayerAddress.wrap(msg.sender);
        node.stake += _stake;
        node.endpoint = _endpoint;
        node.index = ds.relayerCount;
        uint256 length = _accounts.length;
        for (uint256 i = 0; i < length;) {
            node.isAccount[_accounts[i]] = true;
            unchecked {
                ++i;
            }
        }
        ds.relayerIndexToRelayer[node.index] = relayerId;
        ++ds.relayerCount;

        // Update stake array and hash
        uint32[] memory newStakeArray = _addNewRelayerToStakeArray(_previousStakeArray, _stake);
        uint32[] memory newDelegationArray = _addNewRelayerToDelegationArray(_currentDelegationArray);
        _updateAccountingState(newStakeArray, true, newDelegationArray, true);

        emit RelayerRegistered(relayerId, RelayerAddress.wrap(msg.sender), _endpoint, _accounts, _stake);

        return relayerId;
    }

    /// @notice a relayer un unregister, which removes it from the relayer list and a delay for withdrawal is imposed on funds
    // TODO: What happens if relayer has delegation?
    function unRegister(
        uint32[] calldata _previousStakeArray,
        uint32[] calldata _previousDelegationArray,
        RelayerId _relayerId
    )
        external
        override
        verifyStakeArrayHash(_previousStakeArray)
        verifyDelegationArrayHash(_previousDelegationArray)
        onlyRelayerOwner(_relayerId)
    {
        RMStorage storage ds = getRMStorage();

        RelayerInfo storage node = ds.relayerInfo[_relayerId];
        ds.withdrawalInfo[_relayerId] =
            WithdrawalInfo(node.relayerAddress, node.stake, block.timestamp + ds.withdrawDelay);
        uint256 n = ds.relayerCount - 1;
        uint256 nodeIndex = node.index;
        delete ds.relayerInfo[_relayerId];

        if (nodeIndex != n) {
            RelayerId lastRelayer = ds.relayerIndexToRelayer[n];
            ds.relayerIndexToRelayer[nodeIndex] = lastRelayer;
            ds.relayerInfo[lastRelayer].index = nodeIndex;
            ds.relayerIndexToRelayer[n] = RelayerId.wrap(bytes32(0));
        }

        --ds.relayerCount;

        // Update stake percentages array and hash
        uint32[] memory newStakeArray = _removeRelayerFromStakeArray(_previousStakeArray, nodeIndex);
        uint32[] memory newDelegationArray = _removeRelayerFromDelegationArray(_previousDelegationArray, nodeIndex);
        _updateAccountingState(newStakeArray, true, newDelegationArray, true);
        emit RelayerUnRegistered(_relayerId);
    }

    function withdraw(RelayerId _relayerId) external override {
        RMStorage storage ds = getRMStorage();

        WithdrawalInfo memory w = ds.withdrawalInfo[_relayerId];
        if (!(w.amount > 0 && w.time < block.timestamp)) {
            revert InvalidWithdrawal(w.amount, block.timestamp, w.time);
        }
        delete ds.withdrawalInfo[_relayerId];
        _transfer(TokenAddress.wrap(address(ds.bondToken)), RelayerAddress.unwrap(w.withdrawlAddress), w.amount);
        emit Withdraw(_relayerId, w.amount);
    }

    function setRelayerAccountsStatus(
        RelayerId _relayerId,
        RelayerAccountAddress[] calldata _accounts,
        bool[] calldata _status
    ) external override onlyStakedRelayer(_relayerId) onlyRelayerOwner(_relayerId) {
        if (_accounts.length != _status.length) {
            revert ParameterLengthMismatch();
        }

        RMStorage storage ds = getRMStorage();
        RelayerInfo storage node = ds.relayerInfo[_relayerId];

        uint256 length = _accounts.length;
        for (uint256 i = 0; i < length;) {
            node.isAccount[_accounts[i]] = _status[i];
            unchecked {
                ++i;
            }
        }

        emit RelayerAccountsUpdated(_relayerId, _accounts, _status);
    }

    function processAbsenceProof(
        AbsenceProofReporterData calldata _reporterData,
        AbsenceProofAbsenteeData calldata _absenteeData,
        uint32[] calldata _currentStakeArray,
        uint32[] calldata _currentDelegationArray
    )
        public
        override
        verifyCdfHash(_reporterData.cdf)
        verifyStakeArrayHash(_currentStakeArray)
        verifyDelegationArrayHash(_currentDelegationArray)
    {
        uint256 gas = gasleft();

        RelayerAccountAddress reporter_relayerAddress = RelayerAccountAddress.wrap(msg.sender);
        RelayerInfo storage absence_relayerInfo = getRMStorage().relayerInfo[_absenteeData.relayerId];

        if (
            !(_reporterData.relayerGenerationIterations.length == 1)
                || !(_reporterData.relayerGenerationIterations[0] == ABSENTEE_PROOF_REPORTER_GENERATION_ITERATION)
        ) {
            revert InvalidRelayerWindowForReporter();
        }

        // Verify Reporter Selection in Current Window
        if (
            !_verifyRelayerSelection(
                RelayerAccountAddress.unwrap(reporter_relayerAddress),
                _reporterData.cdf,
                _reporterData.cdfIndex,
                _reporterData.relayerGenerationIterations,
                block.number
            )
        ) {
            revert InvalidRelayerWindowForReporter();
        }

        {
            RMStorage storage ds = getRMStorage();

            // Absentee block must not be in a point before the contract was deployed
            if (_absenteeData.blockNumber < ds.penaltyDelayBlocks) {
                revert InvalidAbsenteeBlockNumber();
            }

            {
                // The Absentee block must not be in the current window
                uint256 currentWindowStartBlock = block.number - (block.number % ds.blocksPerWindow);
                if (_absenteeData.blockNumber >= currentWindowStartBlock) {
                    revert InvalidAbsenteeBlockNumber();
                }
            }
        }

        {
            // Verify CDF hash of the Absentee Window
            uint256 absentee_windowId = _windowIdentifier(_absenteeData.blockNumber);
            if (!_verifyPrevCdfHash(_absenteeData.cdf, absentee_windowId, _absenteeData.latestStakeUpdationCdfLogIndex))
            {
                revert InvalidAbsenteeCdfArrayHash();
            }

            // Verify Absence of the relayer
            TAStorage storage ts = getTAStorage();
            if (ts.attendance[absentee_windowId][_absenteeData.relayerId]) {
                revert AbsenteeWasPresent(absentee_windowId);
            }
        }

        // Verify Relayer Selection in Absentee Window
        if (
            !_verifyRelayerSelection(
                RelayerAddress.unwrap(absence_relayerInfo.relayerAddress),
                _absenteeData.cdf,
                _absenteeData.cdfIndex,
                _absenteeData.relayerGenerationIterations,
                _absenteeData.blockNumber
            )
        ) {
            revert InvalidRelayerWindowForAbsentee();
        }

        emit GenericGasConsumed("Verification", gas - gasleft());
        gas = gasleft();

        // Process penalty
        uint256 penalty = (absence_relayerInfo.stake * ABSENCE_PENALTY) / 10000;
        uint32[] memory newStakeArray =
            _decreaseRelayerStakeInStakeArray(_currentStakeArray, _absenteeData.cdfIndex, _scaleStake(penalty));
        _updateAccountingState(newStakeArray, true, _currentDelegationArray, false);
        _transfer(
            TokenAddress.wrap(address(getRMStorage().bondToken)),
            RelayerAccountAddress.unwrap(reporter_relayerAddress),
            penalty
        );

        emit AbsenceProofProcessed(
            _windowIdentifier(block.number),
            RelayerAccountAddress.unwrap(reporter_relayerAddress),
            _absenteeData.relayerId,
            _windowIdentifier(_absenteeData.blockNumber),
            penalty
        );

        emit GenericGasConsumed("Process Penalty", gas - gasleft());
    }

    ////////////////////////// Relayer Configuration //////////////////////////
    // TODO: Jailed relayers should not be able to update their configuration

    function addSupportedGasTokens(RelayerId _relayerId, TokenAddress[] calldata _tokens)
        external
        override
        onlyStakedRelayer(_relayerId)
        onlyRelayerOwner(_relayerId)
    {
        RMStorage storage ds = getRMStorage();

        RelayerInfo storage node = ds.relayerInfo[_relayerId];

        uint256 length = _tokens.length;
        for (uint256 i = 0; i < length;) {
            TokenAddress token = _tokens[i];

            if (node.isGasTokenSupported[token]) {
                revert GasTokenAlreadySupported(token);
            }

            // Update Mapping
            node.isGasTokenSupported[token] = true;
            node.supportedGasTokens.push(token);

            unchecked {
                ++i;
            }
        }

        emit GasTokensAdded(_relayerId, _tokens);
    }

    function removeSupportedGasTokens(RelayerId _relayerId, TokenAddress[] calldata _tokens)
        external
        override
        onlyStakedRelayer(_relayerId)
        onlyRelayerOwner(_relayerId)
    {
        RMStorage storage ds = getRMStorage();
        RelayerInfo storage node = ds.relayerInfo[_relayerId];

        uint256 length = _tokens.length;
        for (uint256 i = 0; i < length;) {
            TokenAddress token = _tokens[i];

            if (!node.isGasTokenSupported[token]) {
                revert GasTokenNotSupported(token);
            }

            // Update Mapping
            node.isGasTokenSupported[token] = false;

            // Update Array. TODO: Optimize
            uint256 jLength = node.supportedGasTokens.length;
            for (uint256 j = 0; j < jLength;) {
                if (node.supportedGasTokens[j] == token) {
                    node.supportedGasTokens[j] = node.supportedGasTokens[jLength - 1];
                    node.supportedGasTokens.pop();
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        emit GasTokensRemoved(_relayerId, _tokens);
    }

    ////////////////////////// Getters //////////////////////////

    function relayerCount() external view override returns (uint256) {
        return getRMStorage().relayerCount;
    }

    function relayerInfo_Stake(RelayerId _relayerId) external view override returns (uint256) {
        return getRMStorage().relayerInfo[_relayerId].stake;
    }

    function relayerInfo_Endpoint(RelayerId _relayerId) external view override returns (string memory) {
        return getRMStorage().relayerInfo[_relayerId].endpoint;
    }

    function relayerInfo_Index(RelayerId _relayerId) external view override returns (uint256) {
        return getRMStorage().relayerInfo[_relayerId].index;
    }

    function relayerInfo_isAccount(RelayerId _relayerId, RelayerAccountAddress _account)
        external
        view
        override
        returns (bool)
    {
        return getRMStorage().relayerInfo[_relayerId].isAccount[_account];
    }

    function relayerInfo_RelayerAddress(RelayerId _relayerId) external view override returns (RelayerAddress) {
        return getRMStorage().relayerInfo[_relayerId].relayerAddress;
    }

    function relayerInfo_isGasTokenSupported(RelayerId _relayerId, TokenAddress _token)
        external
        view
        override
        returns (bool)
    {
        return getRMStorage().relayerInfo[_relayerId].isGasTokenSupported[_token];
    }

    function relayerInfo_SupportedGasTokens(RelayerId _relayerId)
        external
        view
        override
        returns (TokenAddress[] memory)
    {
        return getRMStorage().relayerInfo[_relayerId].supportedGasTokens;
    }

    function relayersPerWindow() external view override returns (uint256) {
        return getRMStorage().relayersPerWindow;
    }

    function blocksPerWindow() external view override returns (uint256) {
        return getRMStorage().blocksPerWindow;
    }

    function cdfHashUpdateLog(uint256 _index) external view override returns (CdfHashUpdateInfo memory) {
        return getRMStorage().cdfHashUpdateLog[_index];
    }

    function stakeArrayHash() external view override returns (bytes32) {
        return getRMStorage().stakeArrayHash;
    }

    function penaltyDelayBlocks() external view override returns (uint256) {
        return getRMStorage().penaltyDelayBlocks;
    }

    function withdrawalInfo(RelayerId _relayerId) external view override returns (WithdrawalInfo memory) {
        return getRMStorage().withdrawalInfo[_relayerId];
    }

    function withdrawDelay() external view override returns (uint256) {
        return getRMStorage().withdrawDelay;
    }

    function bondTokenAddress() external view override returns (TokenAddress) {
        return TokenAddress.wrap(address(getRMStorage().bondToken));
    }

    ////////////////////////// Getters For Derived State //////////////////////////
    function getStakeArray() public view override returns (uint32[] memory) {
        RMStorage storage ds = getRMStorage();

        uint256 length = ds.relayerCount;
        uint32[] memory stakeArray = new uint32[](length);
        for (uint256 i = 0; i < length;) {
            stakeArray[i] = _scaleStake(ds.relayerInfo[ds.relayerIndexToRelayer[i]].stake);
            unchecked {
                ++i;
            }
        }
        return stakeArray;
    }

    function getCdfArray() public view override returns (uint16[] memory) {
        uint32[] memory stakeArray = getStakeArray();
        uint32[] memory delegationArray = ITADelegation(address(this)).getDelegationArray();
        (uint16[] memory cdfArray,) = _generateCdfArray(stakeArray, delegationArray);
        return cdfArray;
    }
}
