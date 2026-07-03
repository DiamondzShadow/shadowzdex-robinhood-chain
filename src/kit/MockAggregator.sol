// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chainlink `AggregatorV3Interface`-compatible price feed. On Robinhood
///         Chain MAINNET this is replaced by the real Chainlink equity Data Feed
///         address (Chainlink is the chain's official oracle from block zero) —
///         the consuming code is identical, only the address in config changes.
///         Deployed on testnet so the attestor can oracle-check quotes today.
contract MockAggregator {
    uint8 public constant decimals = 8; // Chainlink USD feeds use 8 decimals
    int256 public answer;
    string public description;
    uint256 public updatedAt;
    address public immutable owner;

    constructor(int256 answer_, string memory description_) {
        answer = answer_;
        description = description_;
        updatedAt = block.timestamp;
        owner = msg.sender;
    }

    /// @notice Update the reference price (owner only) — lets us demo a mispriced
    ///         pool being rejected by the attestor.
    function setAnswer(int256 answer_) external {
        require(msg.sender == owner, "not owner");
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer_, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound)
    {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
