// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "lib/wormhole/ethereum/contracts/interfaces/relayer/IDelivery.sol";
import "lib/wormhole/ethereum/contracts/interfaces/IWormhole.sol";

abstract contract WormholeApplicationStorage {
    bytes32 internal constant WORMHOLE_APPLICATION_STORAGE_SLOT = keccak256("WormholeApplication.storage");

    struct WHStorage {
        IWormhole wormhole;
        IDelivery delivery;
        uint8 receiptVAAConsistencyLevel;
    }

    /* solhint-disable no-inline-assembly */
    function getWHStorage() internal pure returns (WHStorage storage ms) {
        bytes32 slot = WORMHOLE_APPLICATION_STORAGE_SLOT;
        assembly {
            ms.slot := slot
        }
    }
    /* solhint-enable no-inline-assembly */
}
