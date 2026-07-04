// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IntentRouter} from "../src/shadowz/IntentRouter.sol";
import {SwapIntent} from "../src/shadowz/interfaces/IntentTypes.sol";
import {MockERC20} from "../src/kit/MockERC20.sol";
import {MockAggregator} from "../src/kit/MockAggregator.sol";
import {InventoryFillerAdapter} from "../src/shadowz/adapters/InventoryFillerAdapter.sol";

interface Vm {
    function sign(uint256 pk, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 pk) external returns (address);
    function startBroadcast(uint256 pk) external;
    function stopBroadcast() external;
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256);
}

/// @title Prove the InventoryFillerAdapter fills through the LIVE IntentRouter.
///
/// The intent-router settlement path with NO AMM pool: the CRE attestor prices an
/// intent off the Chainlink feed, and this adapter fills it from market-maker
/// inventory at the same on-chain oracle price (minus spread). This is the real
/// day-one mainnet venue — public equity liquidity on RH Chain is still nascent.
///
/// Uses a fresh open-mint MockERC20 stock + a MockAggregator standing in for the
/// real Chainlink feed (identical `latestRoundData` iface — on mainnet only the
/// feed address changes). Testnet mock USDC is 6-dec, exactly like mainnet USDG,
/// so the decimal math proven here transfers 1:1.
///
///   forge script script/ProveInventoryFiller.s.sol --fork-url rh_testnet -vvvv     # sim
///   forge script script/ProveInventoryFiller.s.sol --rpc-url rh_testnet --broadcast --slow
contract ProveInventoryFiller {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant ROUTER = 0xEc00f9cf9483065d888049Af0eF546f1aAc59087;
    address constant USDC = 0xf9bb9944Ae132CD0EB94c021920c122d26CE88cD; // open-mint mock USDC (6-dec, = USDG)
    bytes32 constant VENUE = keccak256("SHADOWZ_RFQ");
    uint16 constant SPREAD_BPS = 20; // 0.20% MM margin
    int256 constant PRICE_USD8 = 200e8; // $200.00 / share

    event FillerBuyProof(uint256 usdcIn, uint256 expStockOut, uint256 got);
    event FillerSellProof(uint256 stockIn, uint256 expUsdcOut, uint256 got);

    function run() external {
        uint256 deployerPk = vm.envOr("DEPLOYER_PK", uint256(0));
        require(deployerPk != 0, "DEPLOYER_PK env var is required");
        address me = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        MockERC20 usdc = MockERC20(USDC);
        MockERC20 stock = new MockERC20("Filler Test Stock", "tFILL", 18);
        MockAggregator feed = new MockAggregator(PRICE_USD8, "tFILL / USD");

        // Deploy adapter bound to the live router, list the market, fund inventory.
        InventoryFillerAdapter adapter =
            new InventoryFillerAdapter(ROUTER, USDC, me, SPREAD_BPS, 1 days, new address[](0), new address[](0));
        adapter.listMarket(address(stock), address(feed));
        usdc.mint(address(adapter), 10_000e6);
        stock.mint(address(adapter), 100e18);

        // Wire the venue + authorize this script as an attestor (deployer holds
        // SIGNER_ADMIN_ROLE + CONFIG_ROLE on the Phase-0 router).
        IntentRouter router = IntentRouter(ROUTER);
        router.setVenue(VENUE, address(adapter), false);
        router.setAttestor(me, true);

        // ── BUY: 100 USDC -> stock at $200, minus 0.20% ──────────────────────
        {
            uint256 amountIn = 100e6;
            uint256 expOut = adapter.quoteOut(USDC, address(stock), amountIn);
            // Independent hand-check: $100/$200 = 0.5 share, * (1 - 0.20%).
            require(expOut == uint256(5e17) * (10_000 - uint256(SPREAD_BPS)) / 10_000, "buy math mismatch");

            SwapIntent memory intent = SwapIntent({
                user: me,
                tokenIn: USDC,
                tokenOut: address(stock),
                amountIn: amountIn,
                minOut: expOut,
                deadline: block.timestamp + 600,
                venue: VENUE,
                nonce: 9001,
                extra: "",
                bridgeFeeAmount: 0,
                sdmTier: 0
            });
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPk, router.hashIntent(intent));

            usdc.mint(me, amountIn);
            usdc.approve(ROUTER, amountIn);
            uint256 before = stock.balanceOf(me);
            uint256 got = router.executeSwap(intent, abi.encodePacked(r, s, v), "");
            require(stock.balanceOf(me) - before == got, "buy: reported != delivered");
            require(got == expOut, "buy: fill != oracle quote");
            emit FillerBuyProof(amountIn, expOut, got);
        }

        // ── SELL: 0.5 stock -> USDC at $200, minus 0.20% ─────────────────────
        {
            uint256 amountIn = 5e17;
            uint256 expOut = adapter.quoteOut(address(stock), USDC, amountIn);
            require(expOut == uint256(100e6) * (10_000 - uint256(SPREAD_BPS)) / 10_000, "sell math mismatch");

            SwapIntent memory intent = SwapIntent({
                user: me,
                tokenIn: address(stock),
                tokenOut: USDC,
                amountIn: amountIn,
                minOut: expOut,
                deadline: block.timestamp + 600,
                venue: VENUE,
                nonce: 9002,
                extra: "",
                bridgeFeeAmount: 0,
                sdmTier: 0
            });
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPk, router.hashIntent(intent));

            stock.mint(me, amountIn);
            stock.approve(ROUTER, amountIn);
            uint256 before = usdc.balanceOf(me);
            uint256 got = router.executeSwap(intent, abi.encodePacked(r, s, v), "");
            require(usdc.balanceOf(me) - before == got, "sell: reported != delivered");
            require(got == expOut, "sell: fill != oracle quote");
            emit FillerSellProof(amountIn, expOut, got);
        }

        vm.stopBroadcast();
    }
}
