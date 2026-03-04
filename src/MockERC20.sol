// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple mintable ERC-20 with configurable decimals.
///         Used as a staking token in tests and local deployment.
contract MockERC20 is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
