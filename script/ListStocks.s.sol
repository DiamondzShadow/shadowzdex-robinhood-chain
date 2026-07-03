// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IntentRouter} from "../src/shadowz/IntentRouter.sol";
import {SwapIntent} from "../src/shadowz/interfaces/IntentTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../src/kit/MockERC20.sol";
import {ConstantProductAdapter} from "../src/kit/ConstantProductAdapter.sol";

interface Vm {
    function sign(uint256 pk, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 pk) external returns (address);
    function startBroadcast(uint256 pk) external;
    function stopBroadcast() external;
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256);
}

/// @title Phase 1 — list real Robinhood Chain testnet Stock Tokens on ShadowzDex.
///
/// Reuses the LIVE IntentRouter from Phase 0, deploys a constant-product pool per
/// stock (TSLA / AMD / AMZN) seeded with the faucet Stock Tokens + USDC, registers
/// each as a venue, and proves a real buy fills: 100 USDC → TSLA via a signed intent.
///
///   forge script script/ListStocks.s.sol --fork-url rh_testnet -vvvv           # sim
///   forge script script/ListStocks.s.sol --rpc-url rh_testnet --broadcast --slow  # live
contract ListStocks {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Live Phase 0 deployment + our mintable mock USDC (quote asset).
    address constant ROUTER = 0xEc00f9cf9483065d888049Af0eF546f1aAc59087;
    address constant USDC = 0xf9bb9944Ae132CD0EB94c021920c122d26CE88cD;
    // Faucet Stock Tokens (RH Chain testnet, 18-dec).
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant AMD = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    address constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;

    event Listed(string market, address adapter, uint256 usdcSeed, uint256 stockSeed);
    event Bought(address stock, uint256 usdcIn, uint256 stockOut);

    function run() external {
        uint256 deployerPk = vm.envOr(
            "DEPLOYER_PK",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        uint256 attestorPk = vm.envOr("ATTESTOR_PK", uint256(0xA11CE00000000000000000000000000000000000000000000000000000000001));
        address me = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        IntentRouter router = IntentRouter(ROUTER);
        MockERC20 usdc = MockERC20(USDC);
        usdc.mint(me, 100_000e6); // liquidity for the quote side

        // Seed prices ~ real: TSLA ~$300, AMD ~$150, AMZN ~$200.
        address tslaPool = _list(router, usdc, TSLA, "TSLA_MKT", 1_500e6, 5e18);
        _list(router, usdc, AMD, "AMD_MKT", 750e6, 5e18);
        _list(router, usdc, AMZN, "AMZN_MKT", 600e6, 3e18);

        // Prove a real buy through ShadowzDex: 100 USDC -> TSLA.
        uint256 expOut = ConstantProductAdapter(tslaPool).quote(USDC, 100e6);
        SwapIntent memory intent = SwapIntent({
            user: me,
            tokenIn: USDC,
            tokenOut: TSLA,
            amountIn: 100e6,
            minOut: (expOut * 98) / 100,
            deadline: block.timestamp + 600,
            venue: keccak256("TSLA_MKT"),
            nonce: 100,
            extra: "",
            bridgeFeeAmount: 0,
            sdmTier: 0
        });
        bytes32 digest = router.hashIntent(intent);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorPk, digest);

        usdc.approve(ROUTER, 100e6);
        uint256 before = IERC20(TSLA).balanceOf(me);
        uint256 got = router.executeSwap(intent, abi.encodePacked(r, s, v), "");
        require(IERC20(TSLA).balanceOf(me) - before == got, "reported != delivered");
        require(got >= intent.minOut, "below minOut");
        emit Bought(TSLA, 100e6, got);

        vm.stopBroadcast();
    }

    function _list(
        IntentRouter router,
        MockERC20 usdc,
        address stock,
        string memory market,
        uint256 usdcSeed,
        uint256 stockSeed
    ) internal returns (address) {
        ConstantProductAdapter pool = new ConstantProductAdapter(address(usdc), stock);
        usdc.approve(address(pool), usdcSeed);
        IERC20(stock).approve(address(pool), stockSeed);
        pool.seed(usdcSeed, stockSeed);
        router.setVenue(keccak256(bytes(market)), address(pool), false);
        emit Listed(market, address(pool), usdcSeed, stockSeed);
        return address(pool);
    }
}
