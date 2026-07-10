// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {SwapIntent} from "../interfaces/IntentTypes.sol";

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title UniswapV2Adapter (pair-direct)
/// @notice Swap venue backed by Uniswap V2-style AMMs, routed **directly against
///         the pairs** — no periphery Router02 required. Robinhood Chain ships V2
///         *core* (factory `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` + pairs)
///         but no classic `UniswapV2Router02` with `swapExactTokensForTokens`
///         (only Universal-Router-style contracts, which don't expose the legacy
///         interface). So this adapter resolves each hop's pair via the
///         governance-whitelisted factory and performs the low-level swap itself,
///         mirroring `UniswapV2Router02._swap` — the exact constant-product math
///         (0.3% fee) with a fee-on-transfer variant. This also lets it route
///         through brand-new, unindexed pools in one tx.
///
///         Replaces the earlier router-based version. The factory (not a router)
///         is the trust anchor: only pairs created by a whitelisted factory are
///         swapped, so a spoofed pair can't be injected via `adapterData`.
///
/// adapterData encoding:
///   abi.encode(address factory, address[] path, bool feeOnTransfer)
///
///   - factory       MUST be governance-whitelisted (allowedFactory). The attestor
///                   picks which V2 deployment (Uniswap / Pleiades / Sushi) by the
///                   factory whose pairs hold the liquidity.
///   - path[0]       MUST equal intent.tokenIn
///   - path[last]    MUST equal intent.tokenOut
///   - path[i]→path[i+1] each resolve to a live pair via factory.getPair(); a
///                   missing pair reverts (no silent partial route).
///   - feeOnTransfer selects the balance-measuring swap loop for rebasing / tax
///                   tokens. Defaults to false (cheaper).
///
/// The economic guardrail is the IntentRouter's `minOut` check after the adapter
/// returns `amountOut = balanceOf(tokenOut)` — so this adapter itself never gates
/// on a min, it just executes the best on-chain constant-product route the
/// attestor selected and hands the output back to the router.
contract UniswapV2Adapter is IVenueAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant RESCUER_ROLE = keccak256("RESCUER_ROLE");

    /// @notice The IntentRouter allowed to drive this adapter.
    address public immutable ROUTER;

    /// @notice Whitelist of V2 factories whose pairs this adapter may swap through.
    ///         The attestor picks which one (Uniswap / Pleiades / Sushi) based on
    ///         where the pool lives; we resolve the pair on-chain from the chosen
    ///         factory so a fabricated pair address can never be injected.
    mapping(address => bool) public allowedFactory;

    event AllowedFactorySet(address indexed factory, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error OnlyRouter();
    error ZeroAddress();
    error FactoryNotAllowed(address factory);
    error EmptyPath();
    error PathHeadMismatch();
    error PathTailMismatch();
    error NoPair(address tokenA, address tokenB);
    error IdenticalTokens();

    constructor(address router_, address[] memory initialAllowedFactories, address admin) {
        if (router_ == address(0) || admin == address(0)) revert ZeroAddress();
        ROUTER = router_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(RESCUER_ROLE, admin);

        for (uint256 i = 0; i < initialAllowedFactories.length; i++) {
            address f = initialAllowedFactories[i];
            if (f == address(0)) revert ZeroAddress();
            allowedFactory[f] = true;
            emit AllowedFactorySet(f, true);
        }
    }

    function setAllowedFactory(address factory_, bool allowed) external onlyRole(CONFIG_ROLE) {
        if (factory_ == address(0)) revert ZeroAddress();
        allowedFactory[factory_] = allowed;
        emit AllowedFactorySet(factory_, allowed);
    }

    /// @notice Pull any stray balance off the adapter. Real swaps never leave
    ///         dust beyond what's refunded to the user, but every adapter keeps
    ///         the escape hatch.
    function rescueToken(address token, address to, uint256 amount) external onlyRole(RESCUER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @inheritdoc IVenueAdapter
    function execute(SwapIntent calldata intent, bytes calldata adapterData)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.sender != ROUTER) revert OnlyRouter();

        (address factory, address[] memory path, bool feeOnTransfer) =
            abi.decode(adapterData, (address, address[], bool));

        if (!allowedFactory[factory]) revert FactoryNotAllowed(factory);
        if (path.length < 2) revert EmptyPath();
        if (path[0] != intent.tokenIn) revert PathHeadMismatch();
        if (path[path.length - 1] != intent.tokenOut) revert PathTailMismatch();

        // Resolve every hop's pair from the whitelisted factory on-chain — the
        // caller supplies only the token path, never a pair address.
        address[] memory pairs = new address[](path.length - 1);
        for (uint256 i = 0; i < pairs.length; i++) {
            address pair = IUniswapV2Factory(factory).getPair(path[i], path[i + 1]);
            if (pair == address(0)) revert NoPair(path[i], path[i + 1]);
            pairs[i] = pair;
        }

        // Router has already delivered `amountIn` of tokenIn to this contract.
        if (feeOnTransfer) {
            // Seed the first pair, then measure actual received amounts hop-by-hop.
            IERC20(path[0]).safeTransfer(pairs[0], intent.amountIn);
            _swapSupportingFeeOnTransfer(pairs, path, address(this));
        } else {
            uint256[] memory amounts = _getAmountsOut(pairs, path, intent.amountIn);
            IERC20(path[0]).safeTransfer(pairs[0], amounts[0]);
            _swap(pairs, path, amounts, address(this));
        }

        // Sweep tokenOut to the router for fee collection + minOut check.
        amountOut = IERC20(intent.tokenOut).balanceOf(address(this));
        if (amountOut > 0) IERC20(intent.tokenOut).safeTransfer(ROUTER, amountOut);

        // Refund any unused tokenIn straight to the user — V2 pools don't
        // partial-fill, but a fee-on-transfer tokenIn can leave dust.
        uint256 dust = IERC20(intent.tokenIn).balanceOf(address(this));
        if (dust > 0) IERC20(intent.tokenIn).safeTransfer(intent.user, dust);
    }

    // ─── Uniswap V2 core math + swap loop (ported from UniswapV2Library /
    //     UniswapV2Router02, math identical: 0.3% fee, constant product) ───

    /// @dev Deterministic token ordering, matching the pair's own token0/token1.
    function _sortTokens(address tokenA, address tokenB) private pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert IdenticalTokens();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @dev Reserves oriented to (reserveIn, reserveOut) for the given direction.
    function _getReserves(address pair, address tokenIn, address tokenOut)
        private
        view
        returns (uint256 reserveIn, uint256 reserveOut)
    {
        (address token0,) = _sortTokens(tokenIn, tokenOut);
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        (reserveIn, reserveOut) = tokenIn == token0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @dev Constant-product output net of the 0.3% swap fee (997/1000).
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        private
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @dev Per-hop expected outputs for the exact-in path.
    function _getAmountsOut(address[] memory pairs, address[] memory path, uint256 amountIn)
        private
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < pairs.length; i++) {
            (uint256 reserveIn, uint256 reserveOut) = _getReserves(pairs[i], path[i], path[i + 1]);
            amounts[i + 1] = _getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /// @dev Standard V2 swap loop: each pair sends output straight to the next
    ///      pair (or the final recipient), so only one transfer seeds the route.
    function _swap(address[] memory pairs, address[] memory path, uint256[] memory amounts, address to) private {
        for (uint256 i = 0; i < pairs.length; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = _sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address dest = i < pairs.length - 1 ? pairs[i + 1] : to;
            IUniswapV2Pair(pairs[i]).swap(amount0Out, amount1Out, dest, new bytes(0));
        }
    }

    /// @dev Fee-on-transfer variant: derive each hop's input from the pair's
    ///      actual post-transfer balance rather than the nominal amount.
    function _swapSupportingFeeOnTransfer(address[] memory pairs, address[] memory path, address to) private {
        for (uint256 i = 0; i < pairs.length; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = _sortTokens(input, output);
            IUniswapV2Pair pair = IUniswapV2Pair(pairs[i]);
            uint256 amountOutput;
            {
                (uint112 r0, uint112 r1,) = pair.getReserves();
                (uint256 reserveInput, uint256 reserveOutput) =
                    input == token0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
                uint256 amountInput = IERC20(input).balanceOf(address(pair)) - reserveInput;
                amountOutput = _getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
            address dest = i < pairs.length - 1 ? pairs[i + 1] : to;
            pair.swap(amount0Out, amount1Out, dest, new bytes(0));
        }
    }
}
