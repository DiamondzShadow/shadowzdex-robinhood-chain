// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UniswapV2Adapter} from "../../src/shadowz/adapters/UniswapV2Adapter.sol";
import {SwapIntent} from "../../src/shadowz/interfaces/IntentTypes.sol";

/// @title UniswapV2Adapter — fork proof against live Robinhood Chain V2 liquidity.
/// @notice Forks RH mainnet (chain 4663) and drives a real WETH->VIRTUAL swap
///         **directly against the Uniswap V2 pair** (no periphery router — RH
///         ships no classic Router02). VIRTUAL/WETH is RH's deepest V2 market
///         (~$932K TVL, ~$4M/day) and is invisible to the V3-only best-ex today.
///         Asserts the adapter resolves the pair from the whitelisted factory,
///         executes the constant-product swap, sweeps output to the router, and
///         leaves nothing behind.
///
///   forge test --match-contract UniswapV2AdapterForkTest --fork-url rh_mainnet -vvv
contract UniswapV2AdapterForkTest is Test {
    // Live RH mainnet deployment / verified on-chain constants.
    address constant ROUTER = 0x7aaB9e2261bC022b89376F5F6ad0417f076E6e7A;
    address constant V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f; // Uniswap V2 (RH)
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // 18-dec
    address constant VIRTUAL = 0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31; // 18-dec

    UniswapV2Adapter adapter;
    address user = address(0xBEEF);
    address admin = address(0xA11CE);

    function setUp() public {
        address[] memory factories = new address[](1);
        factories[0] = V2_FACTORY;
        adapter = new UniswapV2Adapter(ROUTER, factories, admin);
    }

    function _intent(uint256 amountIn) internal view returns (SwapIntent memory intent) {
        intent = SwapIntent({
            user: user,
            tokenIn: WETH,
            tokenOut: VIRTUAL,
            amountIn: amountIn,
            minOut: 0, // enforced at IntentRouter in prod
            deadline: block.timestamp + 600,
            venue: keccak256("UNISWAP_V2"),
            nonce: 1,
            extra: "",
            bridgeFeeAmount: 0,
            sdmTier: 0
        });
    }

    function _path() internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = WETH;
        path[1] = VIRTUAL;
    }

    function testForkBuyVirtualSingleHop() public {
        uint256 amountIn = 0.1e18; // ~$174 into a ~$932K pool — tiny slippage

        // Router pre-condition: adapter already holds `amountIn` of tokenIn.
        deal(WETH, address(adapter), amountIn);

        SwapIntent memory intent = _intent(amountIn);
        uint256 routerVirtualBefore = IERC20(VIRTUAL).balanceOf(ROUTER);

        bytes memory adapterData = abi.encode(V2_FACTORY, _path(), false);

        vm.prank(ROUTER);
        uint256 amountOut = adapter.execute(intent, adapterData);

        // 1) Real, non-trivial fill against live pair liquidity.
        assertGt(amountOut, 0, "no fill - pair/route broken");

        // 2) Output swept to the router (the post-condition IntentRouter relies on).
        assertEq(
            IERC20(VIRTUAL).balanceOf(ROUTER) - routerVirtualBefore,
            amountOut,
            "amountOut not delivered to router"
        );

        // 3) Adapter holds no capital afterwards.
        assertEq(IERC20(VIRTUAL).balanceOf(address(adapter)), 0, "VIRTUAL stuck in adapter");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "WETH stuck in adapter");

        emit log_named_decimal_uint("WETH in", amountIn, 18);
        emit log_named_decimal_uint("VIRTUAL out", amountOut, 18);
    }

    function testForkOnlyRouterCanExecute() public {
        deal(WETH, address(adapter), 0.01e18);
        bytes memory adapterData = abi.encode(V2_FACTORY, _path(), false);
        vm.expectRevert(UniswapV2Adapter.OnlyRouter.selector);
        adapter.execute(_intent(0.01e18), adapterData); // caller != ROUTER
    }

    function testForkRejectsNonWhitelistedFactory() public {
        deal(WETH, address(adapter), 0.01e18);
        address rogue = address(0xDEAD);
        bytes memory adapterData = abi.encode(rogue, _path(), false);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(UniswapV2Adapter.FactoryNotAllowed.selector, rogue));
        adapter.execute(_intent(0.01e18), adapterData);
    }

    function testForkRevertsWhenNoPair() public {
        deal(WETH, address(adapter), 0.01e18);
        // WETH -> a token with no V2 pair on this factory.
        address orphan = address(0x1234);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = orphan;
        SwapIntent memory intent = _intent(0.01e18);
        intent.tokenOut = orphan;
        bytes memory adapterData = abi.encode(V2_FACTORY, path, false);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(UniswapV2Adapter.NoPair.selector, WETH, orphan));
        adapter.execute(intent, adapterData);
    }
}
