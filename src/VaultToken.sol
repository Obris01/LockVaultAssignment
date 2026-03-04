// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Thrown when minting would exceed the maximum supply cap
error CapExceeded(uint256 requested, uint256 available);
/// @notice Thrown when caller is not the authorized vault contract
error UnauthorizedMinter(address caller);
/// @notice Thrown when trying to set the vault after it has already been set
error VaultAlreadySet();
/// @notice Thrown when trying to finalise with zero address
error ZeroVaultAddress();

/// @title VaultToken
/// @notice ERC-20 reward token for LockVault. Capped at 10,000,000 tokens.
///         Only the designated vault contract may mint new tokens.
///
///         Two-step initialisation:
///           1. Deploy VaultToken (deployer becomes the one-time configurator).
///           2. Deploy LockVault.
///           3. Call setVault(address(lockVault)) — permanently locks the minter.
///         After setVault() is called the vault address cannot be changed again.
///         This avoids fragile constructor-time address prediction.
contract VaultToken is ERC20 {
    uint256 public constant MAX_SUPPLY = 10_000_000 * 1e18;

    /// @notice The deployer permitted to call setVault() exactly once.
    address public immutable DEPLOYER;

    /// @notice The only address permitted to call mint(). Set once via setVault().
    address public VAULT;

    constructor() ERC20("VaultToken", "VTK") {
        DEPLOYER = msg.sender;
    }

    /// @notice Permanently set the vault minter. Can only be called once, by the deployer.
    function setVault(address vault) external {
        if (msg.sender != DEPLOYER) revert UnauthorizedMinter(msg.sender);
        if (VAULT != address(0)) revert VaultAlreadySet();
        if (vault == address(0)) revert ZeroVaultAddress();
        VAULT = vault;
    }

    /// @notice Mint reward tokens. Callable only by the vault contract.
    function mint(address to, uint256 amount) external {
        if (msg.sender != VAULT) revert UnauthorizedMinter(msg.sender);
        uint256 available = MAX_SUPPLY - totalSupply();
        if (amount > available) revert CapExceeded(amount, available);
        _mint(to, amount);
    }
}
