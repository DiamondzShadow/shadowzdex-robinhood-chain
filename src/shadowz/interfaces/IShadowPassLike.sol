// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Any ERC-721 (or contract exposing balanceOf) works as the gate.
///         We use ShadowPass on Arbitrum; on other chains wire whatever NFT.
interface IShadowPassLike {
    function balanceOf(address owner) external view returns (uint256);
}
