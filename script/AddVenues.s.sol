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

/// @title Best-execution — give every market a SECOND venue to route between.
///
/// Phase 1 listed one constant-product pool per stock. An aggregator needs a
/// choice: this deploys a second, independently-priced pool per market and
/// registers it as a new venue (`<SYM>_B`) on the LIVE IntentRouter. The two
/// pools differ on purpose:
///
///   Pool A (`<SYM>_MKT`, Phase 1)  — keener mid-price, shallower depth  → wins SMALL orders
///   Pool B (`<SYM>_B`,   this file) — wider mid-price, deeper reserves   → wins LARGE orders
///
/// Both mids sit inside the 5% Chainlink band, so the attestor signs either.
/// The off-chain best-execution router (copilot/bestex.mjs) quotes both and
/// routes — or splits — to the best fill. Here we prove the on-chain half: a
/// large TSLA buy genuinely quotes higher on Pool B and fills through it.
///
///   forge script script/AddVenues.s.sol --fork-url rh_testnet -vvvv                 # sim
///   forge script script/AddVenues.s.sol --rpc-url rh_testnet --broadcast --slow      # live
contract AddVenues {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant ROUTER = 0xEc00f9cf9483065d888049Af0eF546f1aAc59087;
    address constant USDC = 0xf9bb9944Ae132CD0EB94c021920c122d26CE88cD;

    // Faucet Stock Tokens (RH Chain testnet, 18-dec).
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant AMD = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    address constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;

    // Live Phase 1 pools (Pool A) — quoted here to prove Pool B wins the large order.
    address constant TSLA_A = 0x24014a267D5CfA33e2D8d57082Da2657a304f83F;

    event VenueAdded(string venue, address adapter, uint256 usdcSeed, uint256 stockSeed);
    event BestExProof(uint256 amountIn, uint256 quoteA, uint256 quoteB, address routedTo, uint256 filled);

    function run() external {
        uint256 deployerPk = vm.envOr("DEPLOYER_PK", uint256(0));
        require(deployerPk != 0, "DEPLOYER_PK env var is required");
        uint256 attestorPk = vm.envOr("ATTESTOR_PK", uint256(0));
        require(attestorPk != 0, "ATTESTOR_PK env var is required");
        address me = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        IntentRouter router = IntentRouter(ROUTER);
        MockERC20 usdc = MockERC20(USDC);
        usdc.mint(me, 10_000e6); // USDC for the deeper Pool-B seeds

        // Pool B: wider mid, deeper reserves than the Phase-1 Pool A.
        //   TSLA  mid $306 ($30/ deeper), AMD mid $153, AMZN mid $204.
        address tslaB = _add(router, usdc, TSLA, "TSLA_B", 2_448e6, 8e18);
        _add(router, usdc, AMD, "AMD_B", 918e6, 6e18);
        _add(router, usdc, AMZN, "AMZN_B", 714e6, 35e17); // 3.5 AMZN

        // ── On-chain best-execution proof ──
        // A large 1,000-USDC TSLA buy: shallow Pool A slips hard, deep Pool B wins.
        uint256 amountIn = 1_000e6;
        uint256 qA = ConstantProductAdapter(TSLA_A).quote(USDC, amountIn);
        uint256 qB = ConstantProductAdapter(tslaB).quote(USDC, amountIn);
        require(qB > qA, "expected Pool B to win the large order");

        SwapIntent memory intent = SwapIntent({
            user: me,
            tokenIn: USDC,
            tokenOut: TSLA,
            amountIn: amountIn,
            minOut: (qB * 98) / 100,
            deadline: block.timestamp + 600,
            venue: keccak256("TSLA_B"), // route to the winner
            nonce: 200,
            extra: "",
            bridgeFeeAmount: 0,
            sdmTier: 0
        });
        bytes32 digest = router.hashIntent(intent);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorPk, digest);

        usdc.approve(ROUTER, amountIn);
        uint256 before = IERC20(TSLA).balanceOf(me);
        uint256 got = router.executeSwap(intent, abi.encodePacked(r, s, v), "");
        require(IERC20(TSLA).balanceOf(me) - before == got, "reported != delivered");
        require(got >= intent.minOut, "below minOut");
        emit BestExProof(amountIn, qA, qB, tslaB, got);

        vm.stopBroadcast();
    }

    function _add(
        IntentRouter router,
        MockERC20 usdc,
        address stock,
        string memory venue,
        uint256 usdcSeed,
        uint256 stockSeed
    ) internal returns (address) {
        ConstantProductAdapter pool = new ConstantProductAdapter(address(usdc), stock);
        usdc.approve(address(pool), usdcSeed);
        IERC20(stock).approve(address(pool), stockSeed);
        pool.seed(usdcSeed, stockSeed);
        router.setVenue(keccak256(bytes(venue)), address(pool), false);
        emit VenueAdded(venue, address(pool), usdcSeed, stockSeed);
        return address(pool);
    }
}
