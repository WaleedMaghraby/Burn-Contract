// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ITADelegation.sol";
import "./TADelegationGetters.sol";
import "ta-common/TAHelpers.sol";
import "src/library/arrays/U32ArrayHelper.sol";

contract TADelegation is TADelegationGetters, TAHelpers, ITADelegation {
    using FixedPointTypeHelper for FixedPointType;
    using Uint256WrapperHelper for uint256;
    using U16ArrayHelper for uint16[];
    using U32ArrayHelper for uint32[];
    using RAArrayHelper for RelayerAddress[];
    using SafeERC20 for IERC20;

    function _mintPoolShares(
        RelayerAddress _relayerAddress,
        DelegatorAddress _delegatorAddress,
        uint256 _delegatedAmount,
        TokenAddress _pool
    ) internal {
        TADStorage storage ds = getTADStorage();

        FixedPointType sharePrice_ = _delegationSharePrice(_relayerAddress, _pool, 0);
        FixedPointType sharesMinted = (_delegatedAmount.fp() / sharePrice_);

        ds.shares[_relayerAddress][_delegatorAddress][_pool] =
            ds.shares[_relayerAddress][_delegatorAddress][_pool] + sharesMinted;
        ds.totalShares[_relayerAddress][_pool] = ds.totalShares[_relayerAddress][_pool] + sharesMinted;

        emit SharesMinted(_relayerAddress, _delegatorAddress, _pool, _delegatedAmount, sharesMinted, sharePrice_);
    }

    function _updateRelayerProtocolRewards(RelayerAddress _relayer) internal {
        if (!_isActiveRelayer(_relayer)) {
            return;
        }

        uint256 updatedTotalUnpaidProtocolRewards = _getLatestTotalUnpaidProtocolRewardsAndUpdateUpdatedTimestamp();
        (uint256 relayerRewards, uint256 delegatorRewards, FixedPointType sharesToBurn) =
            _getPendingProtocolRewardsData(_relayer, updatedTotalUnpaidProtocolRewards);

        // Process delegator rewards
        RMStorage storage rs = getRMStorage();
        RelayerInfo storage relayerInfo = rs.relayerInfo[_relayer];

        if (delegatorRewards > 0) {
            _addDelegatorRewards(_relayer, TokenAddress.wrap(address(rs.bondToken)), delegatorRewards);
        }

        // Process relayer rewards
        if (relayerRewards > 0) {
            relayerInfo.unpaidProtocolRewards += relayerRewards;
            emit RelayerProtocolRewardsGenerated(_relayer, relayerRewards);
        }

        rs.totalUnpaidProtocolRewards = updatedTotalUnpaidProtocolRewards - relayerRewards - delegatorRewards;
        rs.totalProtocolRewardShares = rs.totalProtocolRewardShares - sharesToBurn;
        relayerInfo.rewardShares = relayerInfo.rewardShares - sharesToBurn;
    }

    function _mintAllPoolShares(RelayerAddress _relayerAddress, DelegatorAddress _delegator, uint256 _amount)
        internal
    {
        TADStorage storage ds = getTADStorage();
        uint256 length = ds.supportedPools.length;
        if (length == 0) {
            revert NoSupportedGasTokens();
        }

        for (uint256 i; i != length;) {
            _mintPoolShares(_relayerAddress, _delegator, _amount, ds.supportedPools[i]);
            unchecked {
                ++i;
            }
        }
    }

    function delegate(RelayerState calldata _latestState, uint256 _relayerIndex, uint256 _amount)
        external
        override
        noSelfCall
    {
        if (_relayerIndex >= _latestState.relayers.length) {
            revert InvalidRelayerIndex();
        }

        _verifyExternalStateForRelayerStateUpdation(_latestState.cdf.cd_hash(), _latestState.relayers.cd_hash());

        RelayerAddress relayerAddress = _latestState.relayers[_relayerIndex];
        _updateRelayerProtocolRewards(relayerAddress);

        getRMStorage().bondToken.safeTransferFrom(msg.sender, address(this), _amount);
        TADStorage storage ds = getTADStorage();

        // Mint Shares for all supported pools
        DelegatorAddress delegatorAddress = DelegatorAddress.wrap(msg.sender);
        _mintAllPoolShares(relayerAddress, delegatorAddress, _amount);

        // Update global counters
        ds.delegation[relayerAddress][delegatorAddress] += _amount;
        ds.totalDelegation[relayerAddress] += _amount;
        emit DelegationAdded(relayerAddress, delegatorAddress, _amount);

        // Update the CDF
        _updateCdf_c(_latestState.relayers);
    }

    struct TokensToBeTransferred {
        TokenAddress token;
        uint256 amount;
    }

    function _processRewards(
        RelayerAddress _relayerAddress,
        TokenAddress _pool,
        DelegatorAddress _delegatorAddress,
        TokenAddress _bondToken,
        uint256 _delegation
    ) internal returns (TokensToBeTransferred memory) {
        TADStorage storage ds = getTADStorage();

        uint256 rewardsEarned_ = _delegationRewardsEarned(_relayerAddress, _pool, _delegatorAddress);

        if (rewardsEarned_ != 0) {
            ds.unclaimedRewards[_relayerAddress][_pool] -= rewardsEarned_;
        }

        ds.totalShares[_relayerAddress][_pool] =
            ds.totalShares[_relayerAddress][_pool] - ds.shares[_relayerAddress][_delegatorAddress][_pool];
        ds.shares[_relayerAddress][_delegatorAddress][_pool] = FP_ZERO;

        return TokensToBeTransferred({
            token: _pool,
            amount: _pool == _bondToken ? rewardsEarned_ + _delegation : rewardsEarned_
        });
    }

    function undelegate(RelayerState calldata _latestState, RelayerAddress _relayerAddress)
        external
        override
        noSelfCall
    {
        _verifyExternalStateForRelayerStateUpdation(_latestState.cdf.cd_hash(), _latestState.relayers.cd_hash());

        TADStorage storage ds = getTADStorage();

        _updateRelayerProtocolRewards(_relayerAddress);

        uint256 delegation_ = ds.delegation[_relayerAddress][DelegatorAddress.wrap(msg.sender)];
        TokenAddress bondToken = TokenAddress.wrap(address(getRMStorage().bondToken));

        // Burn shares for each pool and calculate rewards
        uint256 length = ds.supportedPools.length;
        TokensToBeTransferred[] memory tokensToBeTransferred = new TokensToBeTransferred[](length);
        for (uint256 i; i != length;) {
            tokensToBeTransferred[i] = _processRewards(
                _relayerAddress, ds.supportedPools[i], DelegatorAddress.wrap(msg.sender), bondToken, delegation_
            );
            unchecked {
                ++i;
            }
        }

        // Update delegation state
        ds.totalDelegation[_relayerAddress] -= delegation_;
        delete ds.delegation[_relayerAddress][DelegatorAddress.wrap(msg.sender)];
        emit DelegationRemoved(_relayerAddress, DelegatorAddress.wrap(msg.sender), delegation_);

        // Transfer the rewards and the original stake
        for (uint256 i; i != length;) {
            TokensToBeTransferred memory t = tokensToBeTransferred[i];
            if (t.amount > 0) {
                _transfer(t.token, msg.sender, t.amount);
                emit RewardSent(_relayerAddress, DelegatorAddress.wrap(msg.sender), t.token, t.amount);
            }
            unchecked {
                ++i;
            }
        }

        // Update the CDF if and only if the relayer is still registered
        // There can be a case where the relayer is unregistered and the user still has rewards
        if (_isActiveRelayer(_relayerAddress)) {
            _updateCdf_c(_latestState.relayers);
        }
    }

    function _delegationSharePrice(
        RelayerAddress _relayerAddress,
        TokenAddress _tokenAddress,
        uint256 _extraUnclaimedRewards
    ) internal view returns (FixedPointType) {
        TADStorage storage ds = getTADStorage();
        FixedPointType totalShares_ = ds.totalShares[_relayerAddress][_tokenAddress];

        if (totalShares_ == FP_ZERO) {
            return FP_ONE;
        }

        return (
            ds.totalDelegation[_relayerAddress] + ds.unclaimedRewards[_relayerAddress][_tokenAddress]
                + _extraUnclaimedRewards
        ).fp() / totalShares_;
    }

    function _delegationRewardsEarned(
        RelayerAddress _relayerAddress,
        TokenAddress _tokenAddress,
        DelegatorAddress _delegatorAddress
    ) internal view returns (uint256) {
        TADStorage storage ds = getTADStorage();

        FixedPointType currentValue = ds.shares[_relayerAddress][_delegatorAddress][_tokenAddress]
            * _delegationSharePrice(_relayerAddress, _tokenAddress, 0);
        FixedPointType delegation_ = ds.delegation[_relayerAddress][_delegatorAddress].fp();

        if (currentValue >= delegation_) {
            return (currentValue - delegation_).u256();
        }
        return 0;
    }

    function claimableDelegationRewards(
        RelayerAddress _relayerAddress,
        TokenAddress _tokenAddress,
        DelegatorAddress _delegatorAddress
    ) external view noSelfCall returns (uint256) {
        TADStorage storage ds = getTADStorage();

        uint256 protocolDelegationRewards;

        if (TokenAddress.unwrap(_tokenAddress) == address(getRMStorage().bondToken)) {
            uint256 updatedTotalUnpaidProtocolRewards = _getLatestTotalUnpaidProtocolRewards();

            (, protocolDelegationRewards,) =
                _getPendingProtocolRewardsData(_relayerAddress, updatedTotalUnpaidProtocolRewards);
        }

        FixedPointType currentValue = ds.shares[_relayerAddress][_delegatorAddress][_tokenAddress]
            * _delegationSharePrice(_relayerAddress, _tokenAddress, protocolDelegationRewards);
        FixedPointType delegation_ = ds.delegation[_relayerAddress][_delegatorAddress].fp();

        if (currentValue >= delegation_) {
            return (currentValue - delegation_).u256();
        }
        return 0;
    }

    function addDelegationRewards(RelayerAddress _relayerAddress, uint256 _tokenIndex, uint256 _amount)
        external
        payable
        override
        noSelfCall
    {
        TADStorage storage ds = getTADStorage();

        if (_tokenIndex >= ds.supportedPools.length) {
            revert InvalidTokenIndex();
        }
        TokenAddress tokenAddress = ds.supportedPools[_tokenIndex];

        // Accept the tokens
        if (tokenAddress != NATIVE_TOKEN) {
            IERC20(TokenAddress.unwrap(tokenAddress)).safeTransferFrom(msg.sender, address(this), _amount);
        } else if (msg.value != _amount) {
            revert NativeAmountMismatch();
        }

        // Add to unclaimed rewards
        _addDelegatorRewards(_relayerAddress, tokenAddress, _amount);
    }
}
