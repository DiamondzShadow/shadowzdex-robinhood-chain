// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IntentRouter} from "../src/shadowz/IntentRouter.sol";
import {SwapIntent} from "../src/shadowz/interfaces/IntentTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../src/kit/MockERC20.sol";
import {MockUniswapV2} from "../src/kit/MockUniswapV2.sol";
import {UniswapV2Adapter} from "../src/shadowz/adapters/UniswapV2Adapter.sol";

interface Vm {
    function sign(uint256 pk, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 pk) external returns (address);
    function startBroadcast(uint256 pk) external;
    function stopBroadcast() external;
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256);
}

/// @title Prove the mainnet UniswapV2Adapter fills through the LIVE IntentRouter.
///
/// Robinhood Chain's spot AMMs are Uniswap V2 + Pleiades (both V2-style). This
/// registers the production `UniswapV2Adapter` on the live Phase-0 router and
/// fills an attestor-signed intent through a Uniswap-V2 pool — the exact path a
/// mainnet swap takes, only the pool here is a `MockUniswapV2` stand-in (our
/// faucet Stock Tokens have no real V2 pairs on testnet). On mainnet the same
/// adapter is registered once and `adapterData` names the real Uniswap/Pleiades
/// router + pair; nothing else changes.
///
///   forge script script/ProveUniV2.s.sol --fork-url rh_testnet -vvvv                # sim
///   forge script script/ProveUniV2.s.sol --rpc-url rh_testnet --broadcast --slow     # live
contract ProveUniV2 {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant ROUTER = 0xEc00f9cf9483065d888049Af0eF546f1aAc59087;
    address constant USDC = 0xf9bb9944Ae132CD0EB94c021920c122d26CE88cD; // open-mint mock USDC

    event UniV2Proof(address adapter, address pool, address stock, uint256 usdcIn, uint256 expOut, uint256 got);

    function run() external {
        uint256 deployerPk = vm.envOr(
            "DEPLOYER_PK",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        uint256 attestorPk = vm.envOr("ATTESTOR_PK", uint256(0xA11CE00000000000000000000000000000000000000000000000000000000001));
        address me = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        // Fresh mock stock token (open-mint) so the test never touches scarce
        // faucet balances — this proves the ADAPTER path, not a specific listing.
        MockERC20 usdc = MockERC20(USDC);
        MockERC20 stock = new MockERC20("UniV2 Test Stock", "tUNIV2", 18);

        // A Uniswap-V2 pool, seeded ~$200/share (100k USDC / 500 stock).
        MockUniswapV2 pool = new MockUniswapV2(USDC, address(stock));
        usdc.mint(me, 100_000e6);
        stock.mint(me, 500e18);
        usdc.approve(address(pool), 100_000e6);
        stock.approve(address(pool), 500e18);
        pool.seed(
            USDC < address(stock) ? 100_000e6 : 500e18,
            USDC < address(stock) ? 500e18 : 100_000e6
        );

        // Deploy the production adapter, bound to the live router; whitelist the pool's router.
        address[] memory allowed = new address[](1);
        allowed[0] = address(pool);
        UniswapV2Adapter adapter = new UniswapV2Adapter(ROUTER, allowed, me);

        IntentRouter router = IntentRouter(ROUTER);
        router.setVenue(keccak256("UNISWAP_V2"), address(adapter), false);

        // Build + sign an intent to buy the stock with 100 USDC via UniswapV2.
        uint256 amountIn = 100e6;
        (uint256 rIn, uint256 rOut) = _reservesFor(pool, USDC, address(stock));
        uint256 expOut = pool.getAmountOut(amountIn, rIn, rOut);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(stock);
        bytes memory adapterData = abi.encode(address(pool), path, false);

        SwapIntent memory intent = SwapIntent({
            user: me,
            tokenIn: USDC,
            tokenOut: address(stock),
            amountIn: amountIn,
            minOut: (expOut * 98) / 100,
            deadline: block.timestamp + 600,
            venue: keccak256("UNISWAP_V2"),
            nonce: 300,
            extra: "",
            bridgeFeeAmount: 0,
            sdmTier: 0
        });
        bytes32 digest = router.hashIntent(intent);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorPk, digest);

        usdc.approve(ROUTER, amountIn);
        uint256 before = stock.balanceOf(me);
        uint256 got = router.executeSwap(intent, abi.encodePacked(r, s, v), adapterData);
        require(stock.balanceOf(me) - before == got, "reported != delivered");
        require(got >= intent.minOut, "below minOut");
        require(got == expOut, "on-chain fill != off-chain quote"); // exact V2 math match
        emit UniV2Proof(address(adapter), address(pool), address(stock), amountIn, expOut, got);

        vm.stopBroadcast();
    }

    function _reservesFor(MockUniswapV2 pool, address tokenIn, address /*tokenOut*/)
        internal
        view
        returns (uint256 rIn, uint256 rOut)
    {
        (uint112 r0, uint112 r1, ) = pool.getReserves();
        (rIn, rOut) = tokenIn == pool.token0() ? (r0, r1) : (r1, r0);
    }
}
