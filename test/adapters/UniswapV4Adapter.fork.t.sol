// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UniswapV4Adapter, IPoolManager} from "../../src/shadowz/adapters/UniswapV4Adapter.sol";
import {SwapIntent} from "../../src/shadowz/interfaces/IntentTypes.sol";

/// @dev The canonical V4 quoter. Declared as a typed interface rather than
///      `abi.encodeWithSignature`: the param is a DYNAMIC struct (it carries
///      `bytes hookData`), so it needs an offset word that flat-encoding omits.
interface IV4Quoter {
    struct QuoteExactSingleParams {
        IPoolManager.PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    /// @dev Not `view`: it swaps, then reverts with the result and catches it.
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @title UniswapV4Adapter — fork proof against live Robinhood Chain V4 liquidity.
/// @notice Forks RH mainnet (chain 4663) and drives real USDG<->USDe swaps through
///         the live V4 PoolManager. This is the venue that makes USDe tradeable at
///         all: its V3 pools are dust (the 0.01% tier holds 22 wei), so every
///         existing venue returns "no route" and the gateway's Auto tab errors.
///
///   forge test --match-contract UniswapV4AdapterForkTest --fork-url rh_mainnet -vvv
contract UniswapV4AdapterForkTest is Test {
    // Live RH mainnet deployment.
    address constant ROUTER = 0x7aaB9e2261bC022b89376F5F6ad0417f076E6e7A;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6-dec
    address constant USDe = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34; // 18-dec

    // The only USDe pool with real depth: V4 fee=100 / ts=1, hookless.
    // USDe (0x5d3a…) < USDG (0x5fc5…) ⇒ currency0 = USDe.
    uint24 constant FEE = 100;
    int24 constant TICK_SPACING = 1;

    UniswapV4Adapter adapter;
    address user = address(0xBEEF);
    address admin = address(0xA11CE);

    function setUp() public {
        address[] memory pms = new address[](1);
        pms[0] = POOL_MANAGER;
        adapter = new UniswapV4Adapter(ROUTER, pms, admin);
    }

    function _key() internal pure returns (IPoolManager.PoolKey memory) {
        return IPoolManager.PoolKey({
            currency0: USDe,
            currency1: USDG,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(0)
        });
    }

    function _intent(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (SwapIntent memory)
    {
        return SwapIntent({
            user: user,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minOut: 0, // enforced at IntentRouter in prod
            deadline: block.timestamp + 600,
            venue: keccak256("UNISWAP_V4"),
            nonce: 1,
            extra: "",
            bridgeFeeAmount: 0,
            sdmTier: 0
        });
    }

    /// USDG -> USDe (zeroForOne = false, since currency0 is USDe).
    function testForkBuyUsdeFromUsdg() public {
        uint256 amountIn = 1_000e6; // $1,000 USDG

        // Router pre-condition: adapter already holds `amountIn` of tokenIn.
        deal(USDG, address(adapter), amountIn);

        uint256 routerBefore = IERC20(USDe).balanceOf(ROUTER);

        bytes memory adapterData = abi.encode(POOL_MANAGER, _key(), bytes(""));
        vm.prank(ROUTER);
        uint256 amountOut = adapter.execute(_intent(USDG, USDe, amountIn), adapterData);

        uint256 delivered = IERC20(USDe).balanceOf(ROUTER) - routerBefore;
        emit log_named_uint("amountOut returned", amountOut);
        emit log_named_uint("USDe swept to router", delivered);

        assertEq(delivered, amountOut, "output not swept to router");
        assertGt(amountOut, 0, "no output");
        // Stable pair: ~1:1. Guard the decimal scaling (6-dec in, 18-dec out).
        assertGt(amountOut, 990e18, "output implausibly low - check decimals");
        assertLt(amountOut, 1010e18, "output implausibly high - check decimals");

        // Adapter must retain nothing.
        assertEq(IERC20(USDe).balanceOf(address(adapter)), 0, "USDe left on adapter");
        assertEq(IERC20(USDG).balanceOf(address(adapter)), 0, "USDG left on adapter");
    }

    /// USDe -> USDG (zeroForOne = true). Proves both directions settle.
    function testForkSellUsdeForUsdg() public {
        uint256 amountIn = 500e18; // 500 USDe

        deal(USDe, address(adapter), amountIn);
        uint256 routerBefore = IERC20(USDG).balanceOf(ROUTER);

        bytes memory adapterData = abi.encode(POOL_MANAGER, _key(), bytes(""));
        vm.prank(ROUTER);
        uint256 amountOut = adapter.execute(_intent(USDe, USDG, amountIn), adapterData);

        uint256 delivered = IERC20(USDG).balanceOf(ROUTER) - routerBefore;
        emit log_named_uint("USDG swept to router", delivered);

        assertEq(delivered, amountOut, "output not swept to router");
        assertGt(amountOut, 495e6, "output implausibly low");
        assertLt(amountOut, 505e6, "output implausibly high");
        assertEq(IERC20(USDG).balanceOf(address(adapter)), 0, "USDG left on adapter");
    }

    /// The adapter's quote must agree with the canonical V4Quoter, or best-ex is
    /// signing a number the fill won't honour.
    function testForkMatchesV4Quoter() public {
        uint256 amountIn = 1_000e6;

        (uint256 quoted,) = IV4Quoter(V4_QUOTER).quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: _key(),
                zeroForOne: false, // USDG -> USDe
                exactAmount: uint128(amountIn),
                hookData: bytes("")
            })
        );

        deal(USDG, address(adapter), amountIn);
        bytes memory adapterData = abi.encode(POOL_MANAGER, _key(), bytes(""));
        vm.prank(ROUTER);
        uint256 actual = adapter.execute(_intent(USDG, USDe, amountIn), adapterData);

        emit log_named_uint("V4Quoter said", quoted);
        emit log_named_uint("adapter delivered", actual);
        assertEq(actual, quoted, "adapter fill != V4Quoter quote");
    }

    /// Only the IntentRouter may drive the adapter.
    function testForkOnlyRouter() public {
        deal(USDG, address(adapter), 1_000e6);
        bytes memory adapterData = abi.encode(POOL_MANAGER, _key(), bytes(""));
        vm.expectRevert(UniswapV4Adapter.OnlyRouter.selector);
        vm.prank(user);
        adapter.execute(_intent(USDG, USDe, 1_000e6), adapterData);
    }

    /// A non-whitelisted PoolManager is refused even if it is a real contract.
    function testForkPoolManagerNotAllowed() public {
        deal(USDG, address(adapter), 1_000e6);
        bytes memory adapterData = abi.encode(V4_QUOTER, _key(), bytes("")); // real, not whitelisted
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4Adapter.PoolManagerNotAllowed.selector, V4_QUOTER)
        );
        vm.prank(ROUTER);
        adapter.execute(_intent(USDG, USDe, 1_000e6), adapterData);
    }

    /// THE security property: adapterData chooses WHICH POOL, never WHICH ASSETS.
    /// A pool whose currencies don't match the signed intent must revert rather
    /// than quietly swapping the user into a different token.
    function testForkPoolKeyMustMatchIntent() public {
        deal(USDG, address(adapter), 1_000e6);

        IPoolManager.PoolKey memory wrong = _key();
        wrong.currency0 = address(0xDEAD); // pool that isn't the intent's pair

        bytes memory adapterData = abi.encode(POOL_MANAGER, wrong, bytes(""));
        vm.expectRevert(UniswapV4Adapter.PoolKeyMismatch.selector);
        vm.prank(ROUTER);
        adapter.execute(_intent(USDG, USDe, 1_000e6), adapterData);
    }

    /// unlockCallback is only reachable as the PoolManager re-entering our own
    /// unlock — never from outside, where `_unlocking` is zero.
    function testForkUnlockCallbackNotCallableDirectly() public {
        vm.expectRevert(UniswapV4Adapter.NotUnlocking.selector);
        adapter.unlockCallback("");

        vm.expectRevert(UniswapV4Adapter.NotUnlocking.selector);
        vm.prank(POOL_MANAGER);
        adapter.unlockCallback("");
    }
}
