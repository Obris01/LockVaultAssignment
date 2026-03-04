// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {VaultToken} from "./VaultToken.sol";
import {MembershipNFT} from "./MembershipNFT.sol";
import {AggregatorV3Interface} from "./MockPriceFeed.sol";

// ---------------------------------------------------------------------------
// Custom errors
// ---------------------------------------------------------------------------
error TokenNotWhitelisted(address token);
error TokenAlreadyWhitelisted(address token);
error ZeroAmount();
error InvalidLockTier();
error StakeNotExpired(uint256 unlockTime);
error StakeAlreadyClaimed(uint256 stakeIndex);
error StakeIndexOutOfBounds(uint256 stakeIndex);
error InvalidTreasury();
error InvalidRewardRate();
error CapReachedRewardSkipped();

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
event Staked(address indexed user, address indexed token, uint256 amount, uint8 lockTier, uint256 stakeIndex);
event Withdrawn(address indexed user, uint256 stakeIndex, uint256 amount, uint256 rewards);
event EmergencyWithdrawn(address indexed user, uint256 stakeIndex, uint256 amount, uint256 penaltyRewards);
event RewardsClaimed(address indexed user, uint256 stakeIndex, uint256 rewards);
event TokenWhitelisted(address indexed token, address priceFeed);
event TokenDelisted(address indexed token);
event RewardRateUpdated(uint256 oldRate, uint256 newRate);
event TreasuryUpdated(address oldTreasury, address newTreasury);

/// @title LockVault
/// @notice Time-locked staking protocol. Users deposit whitelisted ERC-20 tokens for fixed
///         durations and receive VaultToken rewards. MembershipNFT holders earn bonus rewards.
///
/// Access Control:
///   Uses OpenZeppelin Ownable (single-admin pattern). Rationale: the protocol has a small,
///   well-defined set of privileged operations (whitelist, rate, treasury). A single owner
///   key (or multisig behind it) is simpler to reason about and audit than role-based access
///   control, which would add surface area without meaningful benefit at this stage.
///   Trade-off: a compromised owner can delist tokens or change the reward rate, but cannot
///   steal user principal (which is always withdrawable). AccessControl would be preferable
///   if different operators need to manage subsets of admin functions.
///
/// Reward Calculation:
///   rewards = amount * baseRate * elapsed * lockMultiplier / 1e18
///   baseRate is expressed as reward tokens per staked token per second, scaled by 1e18
///   to preserve precision in integer arithmetic. Lock multipliers are stored as numerator/
///   denominator pairs (e.g., 2.5x → 25/10) to avoid floating point.
///
/// Reentrancy:
///   All state mutations (marking stakes as claimed, zeroing amounts) happen BEFORE external
///   calls (token transfers, VaultToken.mint). This checks-effects-interactions pattern is
///   sufficient — ReentrancyGuard would be redundant and adds ~2,300 gas per guarded call.
contract LockVault is Ownable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum LockTier {
        ThirtyDays,
        NinetyDays,
        OneEightyDays
    }

    struct Stake {
        address token;
        uint256 amount;
        LockTier lockTier;
        uint256 startTimestamp;
        bool claimed;
    }

    struct TokenInfo {
        bool whitelisted;
        address priceFeed; // AggregatorV3Interface
    }

    // -------------------------------------------------------------------------
    // Lock tier constants
    // -------------------------------------------------------------------------

    uint256 private constant THIRTY_DAYS = 30 days;
    uint256 private constant NINETY_DAYS = 90 days;
    uint256 private constant ONE_EIGHTY_DAYS = 180 days;

    // Multipliers stored as (numerator, denominator) to represent fractional values exactly.
    // 1x = 10/10, 2.5x = 25/10, 6x = 60/10
    uint256 private constant MULTIPLIER_DENOM = 10;
    uint256[3] private multiplierNum = [10, 25, 60];

    // Membership bonus basis points (10% = 1000 bps, 25% = 2500 bps, 50% = 5000 bps)
    uint256 private constant BPS_DENOM = 10_000;
    uint256[3] private membershipBonusBps = [1000, 2500, 5000];

    // Emergency withdrawal penalty: user forfeits 50% of accrued rewards
    uint256 private constant EMERGENCY_PENALTY_BPS = 5000;

    // Precision scaler for baseRewardRate
    uint256 public constant RATE_PRECISION = 1e18;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    VaultToken public immutable REWARD_TOKEN;
    MembershipNFT public immutable MEMBERSHIP_NFT;
    address public treasury;

    /// @notice Reward tokens emitted per staked token per second, scaled by RATE_PRECISION.
    ///         Example: 1e9 means 1e9/1e18 = 1e-9 reward tokens per staked token per second.
    uint256 public baseRewardRate;

    mapping(address => TokenInfo) public tokenInfos;
    address[] public whitelistedTokens; // for TVL enumeration

    mapping(address => Stake[]) private _stakes;

    // Track total staked per token for TVL calculation
    mapping(address => uint256) public totalStaked;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address initialOwner,
        address _rewardToken,
        address _membershipNft,
        address _treasury,
        uint256 _baseRewardRate
    ) Ownable(initialOwner) {
        if (_treasury == address(0)) revert InvalidTreasury();
        REWARD_TOKEN = VaultToken(_rewardToken);
        MEMBERSHIP_NFT = MembershipNFT(_membershipNft);
        treasury = _treasury;
        baseRewardRate = _baseRewardRate;
    }

    // -------------------------------------------------------------------------
    // Admin functions
    // -------------------------------------------------------------------------

    /// @notice Add a token to the whitelist with an associated Chainlink-compatible price feed.
    function addToken(address token, address priceFeed) external onlyOwner {
        if (tokenInfos[token].whitelisted) revert TokenAlreadyWhitelisted(token);
        tokenInfos[token] = TokenInfo({whitelisted: true, priceFeed: priceFeed});
        whitelistedTokens.push(token);
        emit TokenWhitelisted(token, priceFeed);
    }

    /// @notice Remove a token from the whitelist. Existing stakes are unaffected and
    ///         remain withdrawable — only new deposits are blocked.
    function removeToken(address token) external onlyOwner {
        if (!tokenInfos[token].whitelisted) revert TokenNotWhitelisted(token);
        tokenInfos[token].whitelisted = false;
        // Remove from whitelistedTokens array (order not preserved)
        uint256 len = whitelistedTokens.length;
        for (uint256 i; i < len; ++i) {
            if (whitelistedTokens[i] == token) {
                whitelistedTokens[i] = whitelistedTokens[len - 1];
                whitelistedTokens.pop();
                break;
            }
        }
        emit TokenDelisted(token);
    }

    /// @notice Update the base reward rate (scaled by RATE_PRECISION).
    function setBaseRewardRate(uint256 newRate) external onlyOwner {
        emit RewardRateUpdated(baseRewardRate, newRate);
        baseRewardRate = newRate;
    }

    /// @notice Update the treasury address for penalty fees.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidTreasury();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    // -------------------------------------------------------------------------
    // Staking
    // -------------------------------------------------------------------------

    /// @notice Deposit `amount` of `token` for the given lock tier.
    /// @param token    Whitelisted ERC-20 to stake
    /// @param amount   Amount to deposit (in token's native decimals)
    /// @param lockTier Chosen lock duration
    function stake(address token, uint256 amount, LockTier lockTier) external {
        if (!tokenInfos[token].whitelisted) revert TokenNotWhitelisted(token);
        if (amount == 0) revert ZeroAmount();

        // Effects before interaction
        uint256 stakeIndex = _stakes[msg.sender].length;
        _stakes[msg.sender].push(
            Stake({token: token, amount: amount, lockTier: lockTier, startTimestamp: block.timestamp, claimed: false})
        );
        totalStaked[token] += amount;

        emit Staked(msg.sender, token, amount, uint8(lockTier), stakeIndex);

        // Interaction: transfer tokens in
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    // -------------------------------------------------------------------------
    // Withdrawal
    // -------------------------------------------------------------------------

    /// @notice Withdraw stake after lock period expires, collecting all accrued rewards.
    function withdraw(uint256 stakeIndex) external {
        Stake storage s = _getStake(msg.sender, stakeIndex);
        uint256 unlockTime = s.startTimestamp + _lockDuration(s.lockTier);
        if (block.timestamp < unlockTime) revert StakeNotExpired(unlockTime);

        uint256 rewards = _calculateRewards(s, block.timestamp, msg.sender);
        address token = s.token;
        uint256 amount = s.amount;

        // Effects
        s.claimed = true;
        s.amount = 0;
        totalStaked[token] -= amount;

        emit Withdrawn(msg.sender, stakeIndex, amount, rewards);
        if (rewards > 0) emit RewardsClaimed(msg.sender, stakeIndex, rewards);

        // Interactions
        IERC20(token).safeTransfer(msg.sender, amount);
        if (rewards > 0) {
            _mintRewards(msg.sender, rewards);
        }
    }

    /// @notice Withdraw before lock expires. Forfeits 50% of accrued rewards to treasury.
    function emergencyWithdraw(uint256 stakeIndex) external {
        Stake storage s = _getStake(msg.sender, stakeIndex);

        uint256 accruedRewards = _calculateRewards(s, block.timestamp, msg.sender);
        uint256 penalty = (accruedRewards * EMERGENCY_PENALTY_BPS) / BPS_DENOM;
        uint256 userRewards = accruedRewards - penalty;

        address token = s.token;
        uint256 amount = s.amount;

        // Effects
        s.claimed = true;
        s.amount = 0;
        totalStaked[token] -= amount;

        emit EmergencyWithdrawn(msg.sender, stakeIndex, amount, penalty);
        if (userRewards > 0) emit RewardsClaimed(msg.sender, stakeIndex, userRewards);

        // Interactions
        IERC20(token).safeTransfer(msg.sender, amount);
        if (userRewards > 0) {
            _mintRewards(msg.sender, userRewards);
        }
        if (penalty > 0) {
            _mintRewards(treasury, penalty);
        }
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns all stake structs for `user`.
    function getUserStakes(address user) external view returns (Stake[] memory) {
        return _stakes[user];
    }

    /// @notice Returns pending rewards (in VaultToken wei) for a specific stake.
    ///         Returns 0 for already-claimed stakes.
    function getPendingRewards(address user, uint256 stakeIndex) external view returns (uint256) {
        Stake storage s = _getStakeView(user, stakeIndex);
        if (s.claimed) return 0;
        uint256 elapsed = block.timestamp - s.startTimestamp;
        uint256 maxElapsed = _lockDuration(s.lockTier);
        if (elapsed > maxElapsed) elapsed = maxElapsed;
        return _calculateRewards(s, s.startTimestamp + elapsed, user);
    }

    /// @notice Returns total USD value of all staked tokens, using on-chain price feeds.
    ///         Price feeds return values with 8 decimals (Chainlink standard).
    ///         Token decimals are read via IERC20Metadata so any ERC-20 is handled correctly.
    ///         Result is expressed in USD with 8 decimal places.
    function getTotalValueLocked() external view returns (uint256 tvl) {
        uint256 len = whitelistedTokens.length;
        for (uint256 i; i < len; ++i) {
            address token = whitelistedTokens[i];
            uint256 staked = totalStaked[token];
            if (staked == 0) continue;

            TokenInfo storage info = tokenInfos[token];
            (, int256 price,,,) = AggregatorV3Interface(info.priceFeed).latestRoundData();
            if (price <= 0) continue;

            // USD value (8 dec) = staked (tokenDec) * price (8 dec) / 10**tokenDec
            // Reading token decimals via IERC20Metadata handles 6-dec (USDC), 18-dec, etc.
            uint256 tokenDec = IERC20Metadata(token).decimals();
            // casting to uint256 is safe: price > 0 enforced by the check above
            // forge-lint: disable-next-line(unsafe-typecast)
            tvl += (staked * uint256(price)) / (10 ** tokenDec);
        }
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _getStake(address user, uint256 index) private view returns (Stake storage) {
        if (index >= _stakes[user].length) revert StakeIndexOutOfBounds(index);
        Stake storage s = _stakes[user][index];
        if (s.claimed) revert StakeAlreadyClaimed(index);
        return s;
    }

    function _getStakeView(address user, uint256 index) private view returns (Stake storage) {
        if (index >= _stakes[user].length) revert StakeIndexOutOfBounds(index);
        return _stakes[user][index];
    }

    function _lockDuration(LockTier tier) private pure returns (uint256) {
        if (tier == LockTier.ThirtyDays) return THIRTY_DAYS;
        if (tier == LockTier.NinetyDays) return NINETY_DAYS;
        return ONE_EIGHTY_DAYS;
    }

    /// @dev Compute rewards for a stake up to `asOfTimestamp`.
    ///      Capped at the end of the lock period so rewards don't compound past expiry.
    ///      Membership bonus is checked at call time (applied at claim time, not deposit time).
    function _calculateRewards(Stake storage s, uint256 asOfTimestamp, address user) private view returns (uint256) {
        uint256 lockDuration = _lockDuration(s.lockTier);
        uint256 endTime = s.startTimestamp + lockDuration;
        uint256 effectiveEnd = asOfTimestamp < endTime ? asOfTimestamp : endTime;
        uint256 elapsed = effectiveEnd - s.startTimestamp;

        // base = amount * rate * elapsed / RATE_PRECISION
        uint256 multNum = multiplierNum[uint8(s.lockTier)];
        uint256 base = (s.amount * baseRewardRate * elapsed) / RATE_PRECISION;
        uint256 rewards = (base * multNum) / MULTIPLIER_DENOM;

        // Apply membership bonus if applicable
        uint256 bonus = _getMembershipBonusBps(user);
        rewards = rewards + (rewards * bonus) / BPS_DENOM;

        return rewards;
    }

    /// @dev Returns bonus BPS for a user. Returns 0 if they hold no membership NFT.
    function _getMembershipBonusBps(address user) private view returns (uint256) {
        if (user == address(0)) return 0;
        try MEMBERSHIP_NFT.getTier(user) returns (MembershipNFT.Tier tier) {
            return membershipBonusBps[uint8(tier)];
        } catch {
            return 0;
        }
    }

    /// @dev Mint rewards to `to`. If the cap is reached, silently skips minting to avoid
    ///      bricking withdrawals. Emitting a cap-reached event is omitted for gas efficiency;
    ///      callers relying on rewards should monitor VaultToken.totalSupply().
    function _mintRewards(address to, uint256 amount) private {
        uint256 available = REWARD_TOKEN.MAX_SUPPLY() - REWARD_TOKEN.totalSupply();
        if (available == 0) return;
        uint256 mintable = amount > available ? available : amount;
        REWARD_TOKEN.mint(to, mintable);
    }
}
