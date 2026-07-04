// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice TEST-ONLY minimal Uniswap V2. One contract plays BOTH the pair
///         (getReserves / token0 / token1, for off-chain quoting) and the router
///         (swapExactTokensForTokens, for the adapter to call). Real deployments
///         have distinct pair + router addresses; the UniswapV2Adapter and the
///         off-chain quoter handle both because they read the pair for reserves
///         and call the router for the swap — here they're the same address.
///
///         Implements the exact Uniswap V2 constant-product math (0.30% fee,
///         997/1000) so an on-chain fill matches the off-chain quote. NOT for
///         mainnet — real venues are the chain's Uniswap V2 / Pleiades routers.
contract MockUniswapV2 {
    using SafeERC20 for IERC20;

    address public immutable token0;
    address public immutable token1;
    uint112 private reserve0;
    uint112 private reserve1;

    error Expired();
    error InvalidPath();
    error InsufficientOutput();

    constructor(address tokenA, address tokenB) {
        // Sort like real UniV2 so token0 < token1.
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @notice Add liquidity from the caller (must approve both tokens first).
    function seed(uint256 amt0, uint256 amt1) external {
        IERC20(token0).safeTransferFrom(msg.sender, address(this), amt0);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amt1);
        reserve0 = uint112(uint256(reserve0) + amt0);
        reserve1 = uint112(uint256(reserve1) + amt1);
    }

    /// @notice Uniswap V2 pair interface — reserves in token0/token1 order.
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    /// @notice Uniswap V2 getAmountOut — 0.30% fee, multiply-before-divide.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    /// @notice Uniswap V2 router entry point — single or first-hop of `path`.
    ///         Pulls `amountIn` of path[0] from msg.sender, delivers path[last]
    ///         to `to`. Only single-hop paths are supported by this mock.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert Expired();
        if (path.length != 2) revert InvalidPath();
        uint256 out = _swap(amountIn, path[0], path[1], to);
        if (out < amountOutMin) revert InsufficientOutput();
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        if (block.timestamp > deadline) revert Expired();
        if (path.length != 2) revert InvalidPath();
        uint256 out = _swap(amountIn, path[0], path[1], to);
        if (out < amountOutMin) revert InsufficientOutput();
    }

    function _swap(uint256 amountIn, address tokenIn, address tokenOut, address to) internal returns (uint256 out) {
        require((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0), "bad pair");
        (uint256 rIn, uint256 rOut) = tokenIn == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        out = getAmountOut(amountIn, rIn, rOut);
        if (tokenIn == token0) {
            reserve0 = uint112(rIn + amountIn);
            reserve1 = uint112(rOut - out);
        } else {
            reserve1 = uint112(rIn + amountIn);
            reserve0 = uint112(rOut - out);
        }
        IERC20(tokenOut).safeTransfer(to, out);
    }
}
