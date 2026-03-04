// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {VaultToken, CapExceeded, UnauthorizedMinter} from "../src/VaultToken.sol";
import {MembershipNFT, SoulboundTransferNotAllowed, AlreadyHasMembership} from "../src/MembershipNFT.sol";
import {MockPriceFeed} from "../src/MockPriceFeed.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {
    LockVault,
    StakeNotExpired
} from "../src/LockVault.sol";

contract LockVaultTest is Test {
    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------
    address internal admin    = makeAddr("admin");
    address internal alice    = makeAddr("alice");
    address internal treasury = makeAddr("treasury");

    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------
    LockVault     internal vault;
    VaultToken    internal vaultToken;
    MembershipNFT internal membership;
    MockPriceFeed internal priceFeed;
    MockERC20     internal stakingToken;

    // baseRate: 1e9 / 1e18 reward tokens per staked token per second
    uint256 internal constant BASE_RATE   = 1e9;
    int256  internal constant TOKEN_PRICE = 1_00000000; // $1.00 with 8 decimals

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.startPrank(admin);

        vaultToken   = new VaultToken();
        membership   = new MembershipNFT(admin);
        vault        = new LockVault(admin, address(vaultToken), address(membership), treasury, BASE_RATE);
        vaultToken.setVault(address(vault));

        stakingToken = new MockERC20("Staking Token", "STK", 18);
        priceFeed    = new MockPriceFeed(admin, TOKEN_PRICE);
        vault.addToken(address(stakingToken), address(priceFeed));

        vm.stopPrank();

        stakingToken.mint(alice, 1_000 * 1e18);
        vm.prank(alice);
        stakingToken.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // VaultToken (3 tests)
    // =========================================================================

    function test_VaultToken_MintByVault() public {
        vm.prank(address(vault));
        vaultToken.mint(alice, 100 * 1e18);
        assertEq(vaultToken.balanceOf(alice), 100 * 1e18);
    }

    function test_VaultToken_MintUnauthorizedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedMinter.selector, alice));
        vm.prank(alice);
        vaultToken.mint(alice, 1e18);
    }

    function test_VaultToken_CapEnforced() public {
        uint256 cap = vaultToken.MAX_SUPPLY();
        vm.startPrank(address(vault));
        vaultToken.mint(alice, cap);
        vm.expectRevert(abi.encodeWithSelector(CapExceeded.selector, 1, 0));
        vaultToken.mint(alice, 1);
        vm.stopPrank();
    }

    // =========================================================================
    // MembershipNFT (4 tests)
    // =========================================================================

    function test_Membership_MintAndGetTier() public {
        vm.prank(admin);
        membership.mint(alice, MembershipNFT.Tier.Silver);
        assertEq(uint8(membership.getTier(alice)), uint8(MembershipNFT.Tier.Silver));
    }

    function test_Membership_GetTierCorrect() public {
        vm.prank(admin);
        membership.mint(alice, MembershipNFT.Tier.Gold);
        assertEq(uint8(membership.getTier(alice)), uint8(MembershipNFT.Tier.Gold));
    }

    function test_Membership_DoubleMintReverts() public {
        vm.startPrank(admin);
        membership.mint(alice, MembershipNFT.Tier.Bronze);
        vm.expectRevert(abi.encodeWithSelector(AlreadyHasMembership.selector, alice));
        membership.mint(alice, MembershipNFT.Tier.Gold);
        vm.stopPrank();
    }

    function test_Membership_SoulboundTransferReverts() public {
        vm.prank(admin);
        membership.mint(alice, MembershipNFT.Tier.Bronze);
        vm.prank(alice);
        vm.expectRevert(SoulboundTransferNotAllowed.selector);
        membership.transferFrom(alice, makeAddr("bob"), 0);
    }

    // =========================================================================
    // MockPriceFeed (2 tests)
    // =========================================================================

    function test_PriceFeed_ReturnsConfiguredPrice() public {
        (, int256 price,,,) = priceFeed.latestRoundData();
        assertEq(price, TOKEN_PRICE);
    }

    function test_PriceFeed_OwnerCanUpdatePrice() public {
        vm.prank(admin);
        priceFeed.setPrice(2_00000000);
        (, int256 price,,,) = priceFeed.latestRoundData();
        assertEq(price, 2_00000000);
    }

    // =========================================================================
    // LockVault Core (6 tests)
    // =========================================================================

    function test_Vault_AddTokenToWhitelist() public {
        MockERC20     newToken = new MockERC20("New", "NEW", 18);
        MockPriceFeed newFeed  = new MockPriceFeed(admin, TOKEN_PRICE);
        vm.prank(admin);
        vault.addToken(address(newToken), address(newFeed));
        (bool whitelisted,) = vault.tokenInfos(address(newToken));
        assertTrue(whitelisted);
    }

    function test_Vault_StakeSucceeds() public {
        vm.prank(alice);
        vault.stake(address(stakingToken), 100 * 1e18, LockVault.LockTier.ThirtyDays);

        LockVault.Stake[] memory stakes = vault.getUserStakes(alice);
        assertEq(stakes.length, 1);
        assertEq(stakes[0].amount, 100 * 1e18);
        assertFalse(stakes[0].claimed);
    }

    function test_Vault_WithdrawAfterLockGivesCorrectRewards() public {
        uint256 amount = 100 * 1e18;
        vm.prank(alice);
        vault.stake(address(stakingToken), amount, LockVault.LockTier.ThirtyDays);

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        vault.withdraw(0);

        // rewards = amount * rate * duration / RATE_PRECISION * multiplier (1x)
        uint256 expected = (amount * BASE_RATE * 30 days) / 1e18;
        assertEq(vaultToken.balanceOf(alice), expected);
        assertEq(stakingToken.balanceOf(alice), 1_000 * 1e18); // full principal returned
    }

    function test_Vault_WithdrawBeforeLockReverts() public {
        vm.prank(alice);
        vault.stake(address(stakingToken), 100 * 1e18, LockVault.LockTier.ThirtyDays);

        vm.expectRevert(
            abi.encodeWithSelector(StakeNotExpired.selector, block.timestamp + 30 days)
        );
        vm.prank(alice);
        vault.withdraw(0);
    }

    function test_Vault_EmergencyWithdrawAppliesPenalty() public {
        uint256 amount = 100 * 1e18;
        vm.prank(alice);
        vault.stake(address(stakingToken), amount, LockVault.LockTier.ThirtyDays);

        vm.warp(block.timestamp + 15 days);
        vm.prank(alice);
        vault.emergencyWithdraw(0);

        uint256 accrued  = (amount * BASE_RATE * 15 days) / 1e18;
        uint256 penalty  = accrued / 2;
        uint256 userRewards = accrued - penalty;

        assertEq(stakingToken.balanceOf(alice), 1_000 * 1e18); // full principal back
        assertEq(vaultToken.balanceOf(alice),   userRewards);
        assertEq(vaultToken.balanceOf(treasury), penalty);
    }

    function test_Vault_MembershipBonusAppliedAtClaim() public {
        uint256 amount = 100 * 1e18;

        // Stake WITHOUT membership
        vm.prank(alice);
        vault.stake(address(stakingToken), amount, LockVault.LockTier.ThirtyDays);

        // Grant Gold membership mid-stake
        vm.prank(admin);
        membership.mint(alice, MembershipNFT.Tier.Gold);

        // Withdraw at expiry — Gold bonus (50%) should be applied at claim time
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        vault.withdraw(0);

        uint256 base    = (amount * BASE_RATE * 30 days) / 1e18;
        uint256 bonus   = (base * 5000) / 10_000; // 50% Gold
        assertEq(vaultToken.balanceOf(alice), base + bonus);
    }

    // =========================================================================
    // Access Control (2 tests)
    // =========================================================================

    function test_Access_NonAdminCannotAddToken() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.addToken(address(0), address(0));
    }

    function test_Access_NonAdminCannotSetRewardRate() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.setBaseRewardRate(1e10);
    }

    // =========================================================================
    // TVL (1 test)
    // =========================================================================

    function test_TVL_UsesOraclePriceCorrectly() public {
        vm.prank(alice);
        vault.stake(address(stakingToken), 100 * 1e18, LockVault.LockTier.ThirtyDays);

        // TVL = 100e18 * 1e8 / 1e18 = 100 * 1e8 (100 USD with 8 decimal places)
        // casting TOKEN_PRICE to uint256 is safe: positive compile-time constant
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(vault.getTotalValueLocked(), 100 * uint256(TOKEN_PRICE));
    }

    // =========================================================================
    // Fuzz Test (1 test — mandatory)
    // =========================================================================

    /// @notice Fuzz elapsed time and verify pending rewards never exceed the full-term cap.
    function testFuzz_PendingRewards_NeverExceedFullTerm(uint32 elapsed) public {
        uint256 amount = 100 * 1e18;
        vm.prank(alice);
        vault.stake(address(stakingToken), amount, LockVault.LockTier.ThirtyDays);

        vm.warp(block.timestamp + elapsed);

        uint256 pending  = vault.getPendingRewards(alice, 0);
        uint256 maxRewards = (amount * BASE_RATE * 30 days) / 1e18;
        assertLe(pending, maxRewards);
    }
}
