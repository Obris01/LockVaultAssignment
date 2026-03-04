# LockVault

A time-locked multi-asset staking protocol. Users deposit whitelisted ERC-20 tokens for fixed durations (30 / 90 / 180 days) and earn VaultToken rewards. MembershipNFT holders receive tiered bonus multipliers on top of lock-duration multipliers.

---

## Contracts

| Contract | Description |
|---|---|
| `VaultToken` | ERC-20 reward token, capped at 10M, mintable only by LockVault |
| `MembershipNFT` | Soulbound ERC-721 with Bronze / Silver / Gold tiers |
| `MockPriceFeed` | Chainlink-compatible price oracle for USD TVL reporting |
| `LockVault` | Core protocol: staking, rewards, emergency withdrawal |

---

## Design Decisions

### Access Control

I chose **OpenZeppelin `Ownable`** (single-admin pattern) over `AccessControl`. The protocol's privileged operations form a small, well-defined set: whitelist/delist tokens, update the reward rate, update the treasury address. A single owner key — expected in production to be a multisig — is simpler to audit than a role-based model, which would add contract surface area without meaningful security benefit at this stage. If distinct operators need isolated permissions (e.g., a separate "price-feed updater" role), migrating to `AccessControl` is straightforward and would not require changes to the public interface.

### NFT Minting Authorization

`MembershipNFT` uses `onlyOwner` on the `mint` function. **Trust model:** fully centralised — the contract owner (deployer or admin multisig) is the sole minter. This is appropriate for a controlled launch where membership is granted off-chain (e.g., via purchase or KYC). **Trade-offs:**

- *Pro:* simple, auditable, no on-chain access-control state to manage.
- *Con:* the owner could mint Gold tiers arbitrarily, inflating reward payouts. Mitigated by multisig governance and on-chain event transparency.
- *Alternatives:* a Merkle-drop pattern (users claim with proof), a paid mint, or a separate `MinterRole` on `AccessControl`. Any of these can be added without changing LockVault because `getTier()` is the only external interface the vault uses.

### Stake Data Structure

Each stake is stored as a `Stake` struct in a `mapping(address => Stake[])`. The struct contains: `token`, `amount`, `lockTier`, `startTimestamp`, and `claimed`.

- **Array-of-structs:** allows multiple concurrent stakes per user with O(1) indexed access.
- **`claimed` flag + zero-out `amount`:** prevents double-withdrawal without deleting array entries (deletion would shift indices and break the UX of referencing stakes by index).
- **`LockTier` enum:** avoids storing raw durations; durations are derived at runtime from constants, which saves storage and is less error-prone.

### Reward Calculation & Precision

```
rewards = (amount × baseRate × elapsed / RATE_PRECISION) × lockMultiplierNum / lockMultiplierDenom
```

`baseRate` is scaled by `1e18` (`RATE_PRECISION`) to represent fractional reward rates in integer arithmetic. Lock multipliers are stored as `(numerator, denominator)` pairs — `(10, 10)`, `(25, 10)`, `(60, 10)` — to represent 1×, 2.5×, and 6× exactly without floating point. Membership bonuses use basis points (`/10,000`).

Rewards accumulate linearly and are capped at the lock duration end-time, so a user who delays withdrawal does not earn extra rewards.

### Edge Cases

| Case | Handling |
|---|---|
| Stake 0 tokens | Reverts with `ZeroAmount()` |
| Stake non-whitelisted token | Reverts with `TokenNotWhitelisted(token)` |
| Delist token with active stakes | `removeToken` only blocks *new* deposits. `totalStaked` and stake structs remain intact; users withdraw normally. The `whitelistedTokens` array is updated but `tokenInfos[token]` retains the price feed for any last TVL queries before expiry. |
| Reward cap reached mid-claim | `_mintRewards` computes `available = MAX_SUPPLY - totalSupply()` and mints `min(amount, available)`. Withdrawal always succeeds; rewards are silently reduced. This prevents bricking user withdrawals when the cap is hit. |
| Emergency withdrawal with 0 accrued rewards | Both `userRewards` and `penalty` are 0; no mint calls are made, but principal is returned. |

---

## Security Considerations

**Reentrancy:** All state mutations (marking stakes as `claimed`, zeroing `amount`, reducing `totalStaked`) happen strictly before any external calls (token transfers, `rewardToken.mint`). The checks-effects-interactions pattern eliminates reentrancy risk without the gas overhead of `ReentrancyGuard`.

**Integer overflow:** Solidity 0.8 reverts on overflow. No unchecked blocks are used in reward math paths.

**Oracle manipulation:** `MockPriceFeed` is intentionally centralised; production would use a hardened Chainlink feed with staleness checks. TVL is informational only and does not affect principal or reward math, so oracle manipulation cannot drain user funds.

**Reward inflation:** The 10M cap on VaultToken bounds total reward exposure. The admin can lower `baseRewardRate` if needed.

**Soulbound bypass:** `_update` in `MembershipNFT` blocks all transfers where `from != address(0)`, including `safeTransferFrom`, `transferFrom`, and operator approvals that eventually call `_update`. Approvals alone do nothing without a transfer call.

**Admin key risk:** The owner can delist tokens (blocking new stakes) or change the reward rate, but cannot seize user principal — staked tokens are always withdrawable regardless of admin actions.

---

## Setup & Run Instructions

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation): `curl -L https://foundry.paradigm.xyz | bash && foundryup`

### Install dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-commit
```

### Compile

```bash
forge build
```

### Test

```bash
forge test -vv
```

To run with gas reporting:

```bash
forge test --gas-report
```

### Deploy (local Anvil)

```bash
# In one terminal
anvil

# In another
cp .env.example .env
# Edit .env: set PRIVATE_KEY to one of Anvil's test keys

forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Deploy (Sepolia testnet)

```bash
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Environment variables (`.env`)

```
PRIVATE_KEY=<your_private_key_without_0x>
TREASURY=<treasury_address>          # optional; defaults to deployer
SEPOLIA_RPC_URL=<your_rpc_url>       # for testnet deployment
ETHERSCAN_API_KEY=<key>              # for contract verification
```
