// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {SwapIntent} from "../interfaces/IntentTypes.sol";

/// @notice Minimal Uniswap V4 `PoolManager` surface.
///
///         V4 has no router contract: you call `unlock`, and the PoolManager
///         calls you back. Inside that callback the pool is "open" and every
///         `swap` accrues a signed delta per currency which MUST net to zero
///         before the callback returns, or the PoolManager reverts the lot.
///         Debts are paid with `sync`→transfer→`settle`; credits are collected
///         with `take`.
///
///         Deliberately hand-rolled rather than importing v4-core: the same
///         choice `UniswapV3Adapter` makes for `SwapRouter02`. Only these five
///         functions are needed, and vendoring v4-core (plus its transient
///         storage / custom-type machinery) to reach them would be a large
///         dependency for a small surface.
interface IPoolManager {
    /// @dev v4 wraps these in the `Currency` and `IHooks` user-defined value
    ///      types, which are `address` underneath — identical ABI encoding.
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        /// @dev Negative ⇒ exact-input (the amount is what you put IN).
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);

    /// @return delta Packed `int128 amount0 << 128 | int128 amount1`, signed from
    ///         the caller's perspective: negative = owed by us, positive = owed to us.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 delta);

    /// @notice Snapshot a currency's reserves so the follow-up `settle` can measure
    ///         what arrived. Required before paying an ERC-20 debt.
    function sync(address currency) external;

    /// @notice Credit whatever has landed since `sync` against our debt.
    function settle() external payable returns (uint256 paid);

    /// @notice Collect a credit balance.
    function take(address currency, address to, uint256 amount) external;
}

/// @notice PoolManager calls this back inside `unlock`.
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @title UniswapV4Adapter
/// @notice Uniswap V4 swap venue. Sibling to `UniswapV2Adapter` / `UniswapV3Adapter`
///         — identical security envelope (onlyRouter, governance whitelist, CONFIG /
///         RESCUER roles, sweep tokenOut→ROUTER, dust refund), different plumbing.
///
///         Built for the assets whose depth exists ONLY on V4. On Robinhood Chain
///         that is USDe: its V3 pools are dust (the 0.01% tier is literally 22 wei),
///         while V4 `USDe/USDG fee=100/ts=1` quotes $100k at ~4bps of impact. Without
///         this venue those pairs return "no route" on every venue, which is what
///         makes the gateway's Auto tab error rather than merely route elsewhere.
///
///         Holds NO capital: it JIT-routes the user's `amountIn` through live V4
///         liquidity and sweeps the proceeds to the router. The off-chain best-ex
///         layer picks the pool and oracle-checks it before signing.
///
/// adapterData encoding:
///   abi.encode(address poolManager, PoolKey key, bytes hookData)
///
///   - poolManager MUST be governance-whitelisted (`allowedPoolManager`).
///   - key         the exact pool to trade. `{currency0, currency1}` MUST equal
///                 `{intent.tokenIn, intent.tokenOut}` as a set — checked on-chain,
///                 so a signed intent can't be rerouted into a different asset by
///                 swapping the blob. Swap direction is DERIVED from the intent
///                 (`zeroForOne = tokenIn == currency0`) rather than passed in,
///                 which removes it as something a caller could get wrong.
///   - hookData    forwarded verbatim to the pool's hook; empty for hookless pools.
///
/// minOut is enforced by the IntentRouter against `amountOut` after `execute`
/// returns, so no price limit is imposed here (see `_sqrtPriceLimit`) — a double
/// slippage gate could revert a fill the router would have accepted.
contract UniswapV4Adapter is IVenueAdapter, IUnlockCallback, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant RESCUER_ROLE = keccak256("RESCUER_ROLE");

    /// @dev V4's price bounds. Passing `MIN+1` / `MAX-1` is how V4 spells
    ///      "no limit" — the swap then stops only when amountSpecified is filled
    ///      or liquidity runs out. A literal 0 is rejected by the PoolManager.
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    /// @notice The IntentRouter allowed to drive this adapter.
    address public immutable ROUTER;

    /// @notice Whitelist of V4 PoolManagers this adapter may call.
    mapping(address => bool) public allowedPoolManager;

    /// @dev The PoolManager whose `unlock` is currently in flight, and therefore
    ///      the only address allowed to re-enter via `unlockCallback`. Zero
    ///      outside a swap, so an unsolicited callback has nothing to match.
    ///      `execute` is `nonReentrant`, and the PoolManager re-enters this
    ///      contract by design — so `unlockCallback` CANNOT also take that lock
    ///      (it would deadlock every swap). This is its guard instead.
    address private _unlocking;

    event AllowedPoolManagerSet(address indexed poolManager, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error OnlyRouter();
    error ZeroAddress();
    error PoolManagerNotAllowed(address poolManager);
    error NotUnlocking();
    error UnexpectedCallback(address caller);
    error PoolKeyMismatch();
    error NativeCurrencyUnsupported();
    error AmountTooLarge();
    error NoOutput();

    constructor(address router_, address[] memory initialAllowedPoolManagers, address admin) {
        if (router_ == address(0) || admin == address(0)) revert ZeroAddress();
        ROUTER = router_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(RESCUER_ROLE, admin);

        for (uint256 i = 0; i < initialAllowedPoolManagers.length; i++) {
            address pm = initialAllowedPoolManagers[i];
            if (pm == address(0)) revert ZeroAddress();
            allowedPoolManager[pm] = true;
            emit AllowedPoolManagerSet(pm, true);
        }
    }

    function setAllowedPoolManager(address poolManager_, bool allowed) external onlyRole(CONFIG_ROLE) {
        if (poolManager_ == address(0)) revert ZeroAddress();
        allowedPoolManager[poolManager_] = allowed;
        emit AllowedPoolManagerSet(poolManager_, allowed);
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

        (address poolManager, IPoolManager.PoolKey memory key, bytes memory hookData) =
            abi.decode(adapterData, (address, IPoolManager.PoolKey, bytes));

        if (!allowedPoolManager[poolManager]) revert PoolManagerNotAllowed(poolManager);

        // Native (address(0)) currencies would need `settle{value:}` and a payable
        // receive path. The router deals in ERC-20 (native arrives pre-wrapped as
        // WETH), so refuse rather than half-support it.
        if (key.currency0 == address(0)) revert NativeCurrencyUnsupported();

        // Bind the signed intent to the pool: the blob may choose WHICH pool, never
        // WHICH assets. Direction follows from the intent, so it can't disagree.
        bool zeroForOne;
        if (intent.tokenIn == key.currency0 && intent.tokenOut == key.currency1) {
            zeroForOne = true;
        } else if (intent.tokenIn == key.currency1 && intent.tokenOut == key.currency0) {
            zeroForOne = false;
        } else {
            revert PoolKeyMismatch();
        }

        // amountSpecified is int256 and we negate it for exact-input; anything at or
        // above 2^255 would flip sign. Real fills are nowhere near this — this just
        // means a malformed intent reverts instead of swapping in reverse.
        if (intent.amountIn > uint256(type(int256).max)) revert AmountTooLarge();

        // Router has already delivered `amountIn` of tokenIn to this contract.
        _unlocking = poolManager;
        IPoolManager(poolManager).unlock(abi.encode(intent.tokenIn, intent.tokenOut, intent.amountIn, key, zeroForOne, hookData));
        _unlocking = address(0);

        // Sweep tokenOut to the router for fee collection + minOut check.
        amountOut = IERC20(intent.tokenOut).balanceOf(address(this));
        if (amountOut == 0) revert NoOutput();
        IERC20(intent.tokenOut).safeTransfer(ROUTER, amountOut);

        // Refund any unused tokenIn to the user (exact-input spends it all, but stay
        // symmetric with the V2/V3 adapters' dust guard).
        uint256 dust = IERC20(intent.tokenIn).balanceOf(address(this));
        if (dust > 0) IERC20(intent.tokenIn).safeTransfer(intent.user, dust);
    }

    /// @notice PoolManager callback — the pool is open for the body of this call.
    /// @dev Reachable ONLY as the PoolManager re-entering our own `unlock` above:
    ///      `_unlocking` is non-zero exclusively for that window, and must be the
    ///      caller. Everything here is derived from `data` we encoded ourselves.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        address poolManager = _unlocking;
        if (poolManager == address(0)) revert NotUnlocking();
        if (msg.sender != poolManager) revert UnexpectedCallback(msg.sender);

        (
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            IPoolManager.PoolKey memory key,
            bool zeroForOne,
            bytes memory hookData
        ) = abi.decode(data, (address, address, uint256, IPoolManager.PoolKey, bool, bytes));

        int256 delta = IPoolManager(poolManager).swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn), // negative ⇒ exact-input
                sqrtPriceLimitX96: _sqrtPriceLimit(zeroForOne)
            }),
            hookData
        );

        // Unpack the signed per-currency deltas and orient them to in/out.
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        int128 deltaIn = zeroForOne ? amount0 : amount1;
        int128 deltaOut = zeroForOne ? amount1 : amount0;

        // Pay what we owe: sync (snapshot), transfer, settle (measure + credit).
        // `deltaIn` is negative — that magnitude is the debt, and it is what the
        // pool actually consumed, which need not equal `amountIn` if a hook took
        // a cut. Paying the debt rather than `amountIn` keeps those pools correct
        // and leaves any remainder to the dust refund.
        if (deltaIn < 0) {
            uint256 owed = uint256(uint128(-deltaIn));
            IPoolManager(poolManager).sync(tokenIn);
            IERC20(tokenIn).safeTransfer(poolManager, owed);
            IPoolManager(poolManager).settle();
        }

        // Collect what we're owed. The router enforces minOut on the swept balance.
        if (deltaOut > 0) {
            IPoolManager(poolManager).take(tokenOut, address(this), uint256(uint128(deltaOut)));
        }

        return "";
    }

    /// @dev "No limit" in V4 terms. The router's minOut is the real slippage gate;
    ///      a price limit here would silently short-fill instead (V4 stops AT the
    ///      limit and returns a partial delta rather than reverting), which would
    ///      then fail minOut anyway — later and less legibly.
    function _sqrtPriceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1;
    }
}
