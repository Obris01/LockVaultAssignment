// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Thrown when attempting to transfer a soulbound token
error SoulboundTransferNotAllowed();
/// @notice Thrown when the address already holds a membership NFT
error AlreadyHasMembership(address account);
/// @notice Thrown when the address has no membership NFT
error NoMembership(address account);

/// @title MembershipNFT
/// @notice Soulbound (non-transferable) membership NFT granting tiered reward bonuses in LockVault.
///
/// Minting Authorization Model:
///   The contract owner (deployer / admin multisig) is the sole authorized minter.
///   Trust model: fully centralised — the owner is trusted to mint the correct tier to the
///   correct address. This is the simplest model and appropriate for a controlled launch where
///   membership is granted off-chain (e.g., via KYC or purchase). Trade-off: the owner could
///   arbitrarily mint Gold to any address, so users must trust the operator. A more decentralised
///   alternative (e.g., a Merkle-drop or paid mint) could be added later without changing the
///   LockVault integration, because getTier() is the only external interface LockVault uses.
contract MembershipNFT is ERC721, Ownable {
    enum Tier {
        Bronze,
        Silver,
        Gold
    }

    struct MembershipData {
        Tier tier;
        uint96 tokenId; // packs into the same 32-byte slot as Tier (1 byte)
    }

    uint256 private _nextTokenId;

    /// @notice Membership data keyed by owner address
    mapping(address => MembershipData) private _memberships;
    /// @notice Reverse lookup: tokenId → owner (needed for _update override)
    mapping(uint256 => address) private _tokenOwner;

    constructor(address initialOwner) ERC721("LockVault Membership", "LVM") Ownable(initialOwner) {}

    /// @notice Mint a membership NFT to `to` with the given `tier`.
    ///         Each address may hold at most one NFT.
    function mint(address to, Tier tier) external onlyOwner {
        if (balanceOf(to) > 0) revert AlreadyHasMembership(to);

        uint256 tokenId = _nextTokenId++;

        // casting to uint96 is safe: explicit bound check on the line above guarantees no truncation
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 tokenId96 = uint96(tokenId);

        _memberships[to] = MembershipData({tier: tier, tokenId: tokenId96});
        _tokenOwner[tokenId] = to;
        _safeMint(to, tokenId);
    }

    /// @notice Returns the membership tier of `user`.
    /// @dev Reverts if the user holds no membership NFT.
    function getTier(address user) external view returns (Tier) {
        if (balanceOf(user) == 0) revert NoMembership(user);
        return _memberships[user].tier;
    }

    // -------------------------------------------------------------------------
    // Soulbound: block all transfers except minting (from == address(0))
    // -------------------------------------------------------------------------

    /// @dev Override ERC-721's internal _update hook.
    ///      Minting (from == address(0)) is allowed; everything else is blocked.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0)) revert SoulboundTransferNotAllowed();
        return super._update(to, tokenId, auth);
    }
}
