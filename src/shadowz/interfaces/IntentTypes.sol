// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Canonical swap intent. Hashed under EIP-712 and signed by the
///         Chainlink CRE attestor. Router + adapters consume it verbatim.
///
/// Fields:
///   user              beneficiary of the output (tokens, NFT, bridged receipt)
///   tokenIn           ERC-20 the user is providing (native asset handled via WETH pre-wrap)
///   tokenOut          final asset the router accounts against minOut
///   amountIn          total amount pulled from user (includes bridgeFeeAmount for action venues)
///   minOut            minimum tokenOut produced; the router reverts otherwise
///   deadline          unix seconds after which the attestation is invalid
///   venue             keccak256 of the venue name (e.g. "ZEROX", "V15_DEPOSIT", "CCIP_SEND")
///   nonce             per-user monotonic nonce to prevent replay
///   extra             venue-specific blob forwarded to adapter (0x calldata, pool addr, tier)
///   bridgeFeeAmount   protocol fee in `tokenIn` units — split 20/80 into FeeVault by the router.
///                     Zero for non-bridge venues.
///   sdmTier           0-5, the SDM holdings tier claimed at intent-sign time. Router
///                     re-verifies against on-chain SDM balance to block flash-loan gaming.
struct SwapIntent {
    address user;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minOut;
    uint256 deadline;
    bytes32 venue;
    uint256 nonce;
    bytes extra;
    uint256 bridgeFeeAmount;
    uint8 sdmTier;
}
