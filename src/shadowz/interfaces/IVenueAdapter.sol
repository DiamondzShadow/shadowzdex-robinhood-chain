// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwapIntent} from "./IntentTypes.sol";

/// @title IVenueAdapter
/// @notice Uniform entry point for every execution venue (0x, Uniswap v4 hook,
///         V15 pool deposit, CCIP cross-chain, ...).
///
/// Router pre-conditions:
///   - Adapter holds `intent.amountIn` of `intent.tokenIn` before this call.
///   - Adapter is responsible for the final disposition of output (transfer
///     to `intent.user` directly, mint an NFT, deposit into a vault, etc.).
///
/// Router post-conditions:
///   - Adapter MUST return the amount of `intent.tokenOut` produced.
///     For pure-swap adapters this is the buy-token delivered to the user.
///     For action adapters (deposit into vault, bridge, ...) this is the
///     intermediate amount that passed the `intent.minOut` gate — e.g. the
///     USDC amount deposited into V15 — so the router can enforce slippage.
interface IVenueAdapter {
    function execute(SwapIntent calldata intent, bytes calldata adapterData)
        external
        returns (uint256 amountOut);
}
