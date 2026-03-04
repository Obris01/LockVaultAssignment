// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Thrown when a price update would set a non-positive price
error InvalidPrice(int256 price);

/// @notice Minimal Chainlink AggregatorV3Interface — only the functions LockVault uses.
///         Modelling after Chainlink (rather than Pyth) because:
///           1. latestRoundData() is the most widely understood oracle pattern in DeFi.
///           2. 8-decimal fixed precision is simpler to reason about for USD prices than
///              Pyth's variable-exponent format, reducing off-by-one risk in TVL math.
///           3. Swapping to a real Chainlink feed in production requires zero changes to
///              LockVault — just replace the MockPriceFeed address.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title MockPriceFeed
/// @notice Configurable mock that satisfies AggregatorV3Interface for testing and local
///         deployment. The owner sets the USD price; LockVault reads it identically to
///         how it would read a production Chainlink feed.
contract MockPriceFeed is AggregatorV3Interface, Ownable {
    int256 private _price;
    uint80 private _roundId;

    constructor(address initialOwner, int256 initialPrice) Ownable(initialOwner) {
        if (initialPrice <= 0) revert InvalidPrice(initialPrice);
        _price = initialPrice;
        _roundId = 1;
    }

    /// @notice Returns 8 — matching Chainlink's standard USD price feed decimals.
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @notice Update the reported price. Only callable by the owner.
    function setPrice(int256 newPrice) external onlyOwner {
        if (newPrice <= 0) revert InvalidPrice(newPrice);
        _roundId++;
        _price = newPrice;
    }

    /// @notice Returns mock round data. All fields except answer and timestamps are synthetic.
    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, _price, block.timestamp, block.timestamp, _roundId);
    }
}
