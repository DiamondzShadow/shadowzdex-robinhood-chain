// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {SwapIntent} from "../interfaces/IntentTypes.sol";

/// @notice Uniswap V3 `SwapRouter02` surface. The `02` router drops `deadline`
///         from the param structs (deadline is a router-level multicall concern),
///         which is why neither struct carries it.
interface IUniswapV3SwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title UniswapV3Adapter
/// @notice Concentrated-liquidity swap venue backed by a Uniswap V3-compatible
///         `SwapRouter02`. This is where Robinhood Chain's real spot depth lives:
///         the deep WETH/USDG book is a set of V3 pools (0.05% tier ~ $1M), while
///         V2 carries only dust. Sibling to `UniswapV2Adapter` — identical
///         security envelope, different router surface.
///
///         Unlike our `InventoryFillerAdapter` (RFQ against our own inventory),
///         this holds NO capital: it JIT-routes the user's `amountIn` through the
///         chain's live V3 liquidity and sweeps the proceeds back to the router.
///         The off-chain best-ex layer picks the pool (fee tier / multi-hop path)
///         and oracle-verifies it against the Chainlink feed before signing.
///
/// adapterData encoding:
///   abi.encode(address v3Router, uint24 fee, bytes path)
///
///   - v3Router  MUST be governance-whitelisted (`allowedRouter`) — the attestor
///               picks which V3 deployment (Uniswap SwapRouter02, forks).
///   - path==""  single-hop: `exactInputSingle` on the (tokenIn, tokenOut, fee)
///               pool. `fee` selects the tier (100/500/3000/10000).
///   - path!=""  multi-hop: `exactInput` over the encoded V3 path
///               (token,fee,token,fee,...,token). `fee` is ignored. The path head
///               MUST equal intent.tokenIn and the tail intent.tokenOut.
///
/// minOut is enforced by the IntentRouter after `execute` returns
/// `amountOut = balanceOf(tokenOut)`, so we pass `amountOutMinimum = 0` to the V3
/// router to avoid a double slippage check that could revert a fill we'd tolerate.
contract UniswapV3Adapter is IVenueAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant RESCUER_ROLE = keccak256("RESCUER_ROLE");

    /// @notice The IntentRouter allowed to drive this adapter.
    address public immutable ROUTER;

    /// @notice Whitelist of V3 routers this adapter may call.
    mapping(address => bool) public allowedRouter;

    event AllowedRouterSet(address indexed router, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error OnlyRouter();
    error ZeroAddress();
    error RouterNotAllowed(address router);
    error BadPath();
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

    /// @notice Pull any stray balance off the adapter. Real swaps leave nothing
    ///         beyond dust refunded to the user, but every adapter keeps the hatch.
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

        (address v3Router, uint24 fee, bytes memory path) =
            abi.decode(adapterData, (address, uint24, bytes));

        if (!allowedRouter[v3Router]) revert RouterNotAllowed(v3Router);

        // Router has already delivered `amountIn` of tokenIn to this contract.
        // Approve the selected V3 router JIT.
        IERC20(intent.tokenIn).forceApprove(v3Router, intent.amountIn);

        if (path.length == 0) {
            // Single-hop through the (tokenIn, tokenOut, fee) pool.
            IUniswapV3SwapRouter02(v3Router).exactInputSingle(
                IUniswapV3SwapRouter02.ExactInputSingleParams({
                    tokenIn: intent.tokenIn,
                    tokenOut: intent.tokenOut,
                    fee: fee,
                    recipient: address(this),
                    amountIn: intent.amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        } else {
            // Multi-hop: the encoded path's endpoints must match the intent so a
            // signed intent can't be silently rerouted to a different asset.
            _requirePathEndpoints(path, intent.tokenIn, intent.tokenOut);
            IUniswapV3SwapRouter02(v3Router).exactInput(
                IUniswapV3SwapRouter02.ExactInputParams({
                    path: path,
                    recipient: address(this),
                    amountIn: intent.amountIn,
                    amountOutMinimum: 0
                })
            );
        }

        // Zero the residual allowance defensively.
        IERC20(intent.tokenIn).forceApprove(v3Router, 0);

        // Sweep tokenOut to the router for fee collection + minOut check.
        amountOut = IERC20(intent.tokenOut).balanceOf(address(this));
        if (amountOut > 0) IERC20(intent.tokenOut).safeTransfer(ROUTER, amountOut);

        // Refund any unused tokenIn to the user (V3 exactInput spends the full
        // amountIn, but stay symmetric with the V2 adapter's dust guard).
        uint256 dust = IERC20(intent.tokenIn).balanceOf(address(this));
        if (dust > 0) IERC20(intent.tokenIn).safeTransfer(intent.user, dust);
    }

    /// @dev A Uniswap V3 path is `token(20) (fee(3) token(20))+`, i.e. 20 bytes
    ///      then one or more 23-byte `fee||token` hops. Verify the head and tail
    ///      addresses match the intent's tokenIn/tokenOut.
    function _requirePathEndpoints(bytes memory path, address tokenIn, address tokenOut) internal pure {
        // Length must be 20 + k*23 for k >= 1 hop.
        if (path.length < 43 || (path.length - 20) % 23 != 0) revert BadPath();

        address head;
        address tail;
        uint256 tailOffset = path.length - 20;
        assembly {
            // First 20 bytes → head address (top 20 bytes of the first word).
            head := shr(96, mload(add(path, 32)))
            // Last 20 bytes → tail address.
            tail := shr(96, mload(add(add(path, 32), tailOffset)))
        }
        if (head != tokenIn) revert PathHeadMismatch();
        if (tail != tokenOut) revert PathTailMismatch();
    }
}
