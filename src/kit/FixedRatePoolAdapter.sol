// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVenueAdapter} from "../shadowz/interfaces/IVenueAdapter.sol";
import {SwapIntent} from "../shadowz/interfaces/IntentTypes.sol";

/// @notice Simplest possible IVenueAdapter: a constant-price "pool" that sells a
///         Stock Token for USDC at a fixed USD price. Enough to prove the full
///         intent → router → adapter → fill pipeline on Robinhood Chain testnet
///         without a live AMM. Swap it for the DodoAdapter / V4SwapAdapter
///         (pointed at Uniswap on RH Chain) once real Stock-Token liquidity exists.
///
/// Router pre-condition: the router has already transferred `intent.amountIn` of
/// tokenIn (USDC, 6-dec) into this adapter. For a pure-swap venue
/// (`isAction = false`) the router measures ITS OWN tokenOut balance delta, so we
/// must deliver the Stock Token (18-dec) to the router (`msg.sender`), which then
/// forwards it to the user.
contract FixedRatePoolAdapter is IVenueAdapter {
    /// @notice Whole-dollar price of the Stock Token, e.g. 200 for $200/share.
    uint256 public immutable priceUsd;

    constructor(uint256 priceUsd_) {
        require(priceUsd_ > 0, "price=0");
        priceUsd = priceUsd_;
    }

    function execute(SwapIntent calldata intent, bytes calldata) external override returns (uint256 out) {
        // USDC (6 dec) → Stock Token (18 dec): scale up 1e12, divide by price.
        out = (intent.amountIn * 1e12) / priceUsd;
        IERC20(intent.tokenOut).transfer(msg.sender, out); // deliver to router
    }
}
