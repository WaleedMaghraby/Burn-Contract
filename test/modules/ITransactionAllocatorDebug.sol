// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "src/transaction-allocator/interfaces/ITransactionAllocator.sol";
import "./debug/interfaces/ITADebug.sol";

interface ITransactionAllocatorDebug is ITransactionAllocator, ITADebug {}