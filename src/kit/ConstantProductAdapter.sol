// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVenueAdapter} from "../shadowz/interfaces/IVenueAdapter.sol";
import {SwapIntent} from "../shadowz/interfaces/IntentTypes.sol";

/// @notice A minimal constant-product (x*y=k) market for a single USDC/Stock-Token
///         pair, exposed to ShadowzDex as an IVenueAdapter. One instance per
///         market (TSLA, AMD, AMZN, ...). Bidirectional: buy the stock with USDC
///         or sell it back. 0.30% fee stays in the pool as LP yield.
///
/// This is a real AMM (genuine price discovery + slippage), unlike the fixed-rate
/// stub — the honest way to "list" the faucet Stock Tokens on our DEX for testnet.
///
/// Router contract (isAction = false): the router transfers `amountIn` of tokenIn
/// into this adapter, then calls execute(); we deliver tokenOut back to the router
/// (msg.sender), which forwards it to the user and enforces `minOut`.
contract ConstantProductAdapter is IVenueAdapter {
    using SafeERC20 for IERC20;

    address public immutable usdc;
    address public immutable stock;
    uint16 public constant FEE_BPS = 30; // 0.30%

    uint256 public reserveUsdc;
    uint256 public reserveStock;

    event Seeded(uint256 usdc, uint256 stock);
    event Traded(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);

    constructor(address usdc_, address stock_) {
        usdc = usdc_;
        stock = stock_;
    }

    /// @notice Add liquidity from the caller. Caller must approve both tokens.
    function seed(uint256 usdcAmt, uint256 stockAmt) external {
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmt);
        IERC20(stock).safeTransferFrom(msg.sender, address(this), stockAmt);
        reserveUsdc += usdcAmt;
        reserveStock += stockAmt;
        emit Seeded(usdcAmt, stockAmt);
    }

    /// @notice Spot quote (view) — how much tokenOut for amountIn, no state change.
    function quote(address tokenIn, uint256 amountIn) external view returns (uint256 out) {
        (uint256 rIn, uint256 rOut) = tokenIn == usdc ? (reserveUsdc, reserveStock) : (reserveStock, reserveUsdc);
        uint256 amtF = (amountIn * (10_000 - FEE_BPS)) / 10_000;
        out = (rOut * amtF) / (rIn + amtF);
    }

    function execute(SwapIntent calldata intent, bytes calldata) external override returns (uint256 out) {
        address tin = intent.tokenIn;
        address tout = intent.tokenOut;
        require((tin == usdc && tout == stock) || (tin == stock && tout == usdc), "bad pair");

        uint256 amountIn = intent.amountIn;
        (uint256 rIn, uint256 rOut) = tin == usdc ? (reserveUsdc, reserveStock) : (reserveStock, reserveUsdc);

        uint256 amtF = (amountIn * (10_000 - FEE_BPS)) / 10_000;
        out = (rOut * amtF) / (rIn + amtF);
        require(out > 0 && out < rOut, "no liquidity");

        if (tin == usdc) {
            reserveUsdc = rIn + amountIn;
            reserveStock = rOut - out;
        } else {
            reserveStock = rIn + amountIn;
            reserveUsdc = rOut - out;
        }
        IERC20(tout).safeTransfer(msg.sender, out); // deliver to router
        emit Traded(tin, amountIn, tout, out);
    }
}
