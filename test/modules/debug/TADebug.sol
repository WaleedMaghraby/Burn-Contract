// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./interfaces/ITADebug.sol";
import "ta-common/TAHelpers.sol";
import "ta-transaction-allocation/TATransactionAllocationStorage.sol";

contract TADebug is ITADebug, TAHelpers, TATransactionAllocationStorage {
    using U16ArrayHelper for uint16[];
    using RAArrayHelper for RelayerAddress[];
    using VersionManager for VersionManager.VersionManagerState;

    function debug_verifyRelayerStateAtWindow(RelayerState calldata _relayerState, uint256 __windowIndex)
        external
        view
        override
        returns (bool)
    {
        return getRMStorage().relayerStateVersionManager.verifyHashAgainstActiveState(
            _getRelayerStateHash(_relayerState.cdf.cd_hash(), _relayerState.relayers.cd_hash()), __windowIndex
        );
    }

    function debug_currentWindowIndex() external view override returns (uint256) {
        return _windowIndex(block.number);
    }

    function debug_relayerStateHash(RelayerState calldata _relayerState) external pure override returns (bytes32) {
        return _getRelayerStateHash(_relayerState.cdf.cd_hash(), _relayerState.relayers.cd_hash());
    }

    function debug_setTransactionsProcessedByRelayer(RelayerAddress _relayerAddress, uint256 _transactionsProcessed)
        external
        override
    {
        getTAStorage().transactionsSubmitted[getTAStorage().epochEndTimestamp][_relayerAddress] = _transactionsProcessed;
    }

    function debug_setTotalTransactionsProcessed(uint256 _transactionsProcessed) external override {
        getTAStorage().totalTransactionsSubmitted[getTAStorage().epochEndTimestamp] = _transactionsProcessed;
    }

    function debug_setRelayerCount(uint256 _relayerCount) external override {
        getRMStorage().relayerCount = _relayerCount;
    }

    function debug_setTotalStake(uint256 _totalStake) external override {
        getRMStorage().totalStake = _totalStake;
    }

    function debug_protocolRewardsSharePrice() external view override returns (FixedPointType) {
        return _protocolRewardRelayerSharePrice(_getLatestTotalUnpaidProtocolRewards());
    }

    function debug_setBaseProtoocolRewardRate(uint256 _rate) external override {
        getRMStorage().baseRewardRatePerMinimumStakePerSec = _rate;
    }

    function debug_getPendingProtocolRewardsData(RelayerAddress _relayerAddress)
        external
        view
        override
        returns (uint256, uint256, FixedPointType)
    {
        return _getPendingProtocolRewardsData(_relayerAddress, _getLatestTotalUnpaidProtocolRewards());
    }

    function test1() external {}
}
