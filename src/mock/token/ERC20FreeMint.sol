// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "openzeppelin-contracts/token/ERC20/ERC20.sol";

contract ERC20FreeMint is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function batchMint(address[] calldata to, uint256[] calldata amount) external {
        require(to.length == amount.length, "ERC20FreeMint: length mismatch");

        for (uint256 i = 0; i < to.length; i++) {
            _mint(to[i], amount[i]);
        }
    }
}
