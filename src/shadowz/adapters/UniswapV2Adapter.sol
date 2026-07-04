// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {SwapIntent} from "../interfaces/IntentTypes.sol";

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @title UniswapV2Adapter
/// @notice Swap venue backed by a Uniswap V2-compatible router — the flavour
///         Robinhood Chain's spot AMMs ship (Uniswap V2 + Pleiades), plus every
///         V2 fork (Sushi V2, PancakeSwap V2). This is the **mainnet** venue that
///         replaces the test-only `ConstantProductAdapter`: instead of our own
///         seeded pool, it routes through the chain's real liquidity.
///
///         Vendored from the ShadowzDex production `SushiV2Adapter` (live on
///         Arbitrum) — logic unchanged; only the name generalised. Unlike an
///         aggregator adapter that forwards opaque calldata, it decodes
///         `adapterData` as a typed multi-hop path and calls the router directly,
///         so it can route through brand-new, unindexed pools in one tx.
///
/// adapterData encoding:
///   abi.encode(address v2Router, address[] path, bool feeOnTransfer)
///
///   - v2Router      MUST be governance-whitelisted (allowedRouter) — the attestor
///                   picks which venue's router (Uniswap / Pleiades / Sushi).
///   - path[0]       MUST equal intent.tokenIn
///   - path[last]    MUST equal intent.tokenOut
///   - feeOnTransfer selects the *SupportingFeeOnTransferTokens router variant for
///                   rebasing / tax tokens. Defaults to false.
///
/// The economic guardrail is the IntentRouter's `minOut` check after the adapter
/// returns `amountOut = balanceOf(tokenOut)`, so this passes 0 to the V2 router.
contract UniswapV2Adapter is IVenueAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant RESCUER_ROLE = keccak256("RESCUER_ROLE");

    /// @notice The IntentRouter allowed to drive this adapter.
    address public immutable ROUTER;

    /// @notice Whitelist of V2 routers this adapter may call. The attestor picks
    ///         which one (Uniswap / Pleiades / Sushi) based on where the pool
    ///         lives; we verify on-chain the chosen router is whitelisted before
    ///         JIT-approving it.
    mapping(address => bool) public allowedRouter;

    event AllowedRouterSet(address indexed router, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error OnlyRouter();
    error ZeroAddress();
    error RouterNotAllowed(address router);
    error EmptyPath();
    error PathHeadMismatch();
    error PathTailMismatch();

    constructor(address router_, address[] memory initialAllowedRouters, address admin) {
        if (router_ == address(0) || admin == address(0)) revert ZeroAddress();
        ROUTER = router_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(RESCUER_ROLE, admin);

        for (uint256 i = 0; i < initialAllowedRouters.length; i++) {
            address r = initialAllowedRouters[i];
            if (r == address(0)) revert ZeroAddress();
            allowedRouter[r] = true;
            emit AllowedRouterSet(r, true);
        }
    }

    function setAllowedRouter(address router_, bool allowed) external onlyRole(CONFIG_ROLE) {
        if (router_ == address(0)) revert ZeroAddress();
        allowedRouter[router_] = allowed;
        emit AllowedRouterSet(router_, allowed);
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

        (address v2Router, address[] memory path, bool feeOnTransfer) =
            abi.decode(adapterData, (address, address[], bool));

        if (!allowedRouter[v2Router]) revert RouterNotAllowed(v2Router);
        if (path.length < 2) revert EmptyPath();
        if (path[0] != intent.tokenIn) revert PathHeadMismatch();
        if (path[path.length - 1] != intent.tokenOut) revert PathTailMismatch();

        // Router has already delivered `amountIn` of tokenIn to this contract.
        // Approve the selected V2 router JIT.
        IERC20(intent.tokenIn).forceApprove(v2Router, intent.amountIn);

        // minOut is enforced at the IntentRouter level after execute() returns,
        // so pass 0 to the V2 router to avoid a double-check that could revert on
        // a price nudge we'd have tolerated via slippage.
        uint256 deadline = intent.deadline;
        if (feeOnTransfer) {
            IUniswapV2Router(v2Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                intent.amountIn, 0, path, address(this), deadline
            );
        } else {
            IUniswapV2Router(v2Router).swapExactTokensForTokens(
                intent.amountIn, 0, path, address(this), deadline
            );
        }

        // Zero the residual allowance defensively.
        IERC20(intent.tokenIn).forceApprove(v2Router, 0);

        // Sweep tokenOut to the router for fee collection + minOut check.
        amountOut = IERC20(intent.tokenOut).balanceOf(address(this));
        if (amountOut > 0) IERC20(intent.tokenOut).safeTransfer(ROUTER, amountOut);

        // Refund any unused tokenIn straight to the user — V2 pools don't
        // partial-fill but a fee-on-transfer tokenIn can end up with dust.
        uint256 dust = IERC20(intent.tokenIn).balanceOf(address(this));
        if (dust > 0) IERC20(intent.tokenIn).safeTransfer(intent.user, dust);
    }
}
