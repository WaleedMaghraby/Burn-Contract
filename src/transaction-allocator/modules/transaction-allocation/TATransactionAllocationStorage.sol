// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "src/transaction-allocator/common/TATypes.sol";

abstract contract TATransactionAllocationStorage {
    bytes32 internal constant TRANSACTION_ALLOCATION_STORAGE_SLOT = keccak256("TransactionAllocation.storage");

    struct TAStorage {
        mapping(address => uint256) nonce;
        // attendance: windowIndex -> relayer -> wasPresent?
        mapping(uint256 => mapping(RelayerAddress => bool)) attendance;
    }

    /* solhint-disable no-inline-assembly */
    function getTAStorage() internal pure returns (TAStorage storage ms) {
        bytes32 slot = TRANSACTION_ALLOCATION_STORAGE_SLOT;
        assembly {
            ms.slot := slot
        }
    }

    /* solhint-enable no-inline-assembly */
}