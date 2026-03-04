// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VaultToken} from "../src/VaultToken.sol";
import {MembershipNFT} from "../src/MembershipNFT.sol";
import {MockPriceFeed} from "../src/MockPriceFeed.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {LockVault} from "../src/LockVault.sol";

/// @title Deploy
/// @notice Deploys the full LockVault protocol using two-step VaultToken initialisation:
///
///   1. VaultToken   — deployed without a minter; deployer holds the one-time setVault() right
///   2. MembershipNFT
///   3. LockVault    — core protocol
///   4. setVault()   — wire LockVault as the authorised VaultToken minter (permanent)
///   5. MockERC20    — mock staking asset
///   6. MockPriceFeed — $1.00 price feed
///   7. Wire-up      — whitelist staking token with price feed
///
/// Usage (local Anvil):
///   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 \
///     --private-key $PRIVATE_KEY --broadcast
///
/// Usage (testnet, e.g., Sepolia):
///   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY --broadcast --verify
///
/// Environment variables required:
///   PRIVATE_KEY  — deployer private key (hex, without 0x prefix)
///   TREASURY     — treasury address; falls back to deployer if unset
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address treasury = vm.envOr("TREASURY", deployer);

        vm.startBroadcast(deployerKey);

        // --- 1. Deploy VaultToken (no vault address needed at construction) ---
        VaultToken vaultToken = new VaultToken();
        console.log("VaultToken deployed at:", address(vaultToken));

        // --- 2. Deploy MembershipNFT ---
        MembershipNFT membershipNft = new MembershipNFT(deployer);
        console.log("MembershipNFT deployed at:", address(membershipNft));

        // --- 3. Deploy LockVault ---
        uint256 baseRewardRate = 1e9;
        LockVault vault = new LockVault(
            deployer,
            address(vaultToken),
            address(membershipNft),
            treasury,
            baseRewardRate
        );
        console.log("LockVault deployed at:", address(vault));

        // --- 4. Wire vault as the authorised minter (permanent, one-time call) ---
        vaultToken.setVault(address(vault));
        console.log("VaultToken minter set to LockVault");

        // --- 5. Deploy mock staking token ---
        MockERC20 stakingToken = new MockERC20("Mock USDC", "mUSDC", 18);
        console.log("MockERC20 (staking token) deployed at:", address(stakingToken));

        // --- 6. Deploy mock price feed ($1.00 with 8 decimals) ---
        MockPriceFeed priceFeed = new MockPriceFeed(deployer, 1_00000000);
        console.log("MockPriceFeed deployed at:", address(priceFeed));

        // --- 7. Whitelist the staking token ---
        vault.addToken(address(stakingToken), address(priceFeed));
        console.log("Staking token whitelisted");

        stakingToken.mint(deployer, 10_000 * 1e18);
        console.log("Minted 10,000 mUSDC to deployer for testing");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("VaultToken:    ", address(vaultToken));
        console.log("MembershipNFT: ", address(membershipNft));
        console.log("LockVault:     ", address(vault));
        console.log("MockERC20:     ", address(stakingToken));
        console.log("MockPriceFeed: ", address(priceFeed));
        console.log("Treasury:      ", treasury);
    }
}
