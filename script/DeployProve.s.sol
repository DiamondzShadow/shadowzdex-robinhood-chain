// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IntentRouter} from "../src/shadowz/IntentRouter.sol";
import {SwapIntent} from "../src/shadowz/interfaces/IntentTypes.sol";
import {MockERC20} from "../src/kit/MockERC20.sol";
import {FixedRatePoolAdapter} from "../src/kit/FixedRatePoolAdapter.sol";

/// Minimal Vm cheatcode surface — avoids pulling forge-std.
interface Vm {
    function sign(uint256 pk, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 pk) external returns (address);
    function startBroadcast(uint256 pk) external;
    function stopBroadcast() external;
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256);
}

/// @title Phase 0 — deploy ShadowzDex IntentRouter on Robinhood Chain and prove a
///        signed intent fills against a Stock-Token pool.
///
/// Simulate (gas-free, real chainId 46630 EIP-712 domain via fork):
///   forge script script/DeployProve.s.sol --fork-url rh_testnet -vvvv
///
/// Broadcast for real (needs testnet ETH at the deployer — faucet):
///   forge script script/DeployProve.s.sol --rpc-url rh_testnet --broadcast \
///     --private-key $DEPLOYER_PK
contract DeployProve {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    bytes32 constant VENUE = keccak256("RH_TESTPOOL");

    event Deployed(address router, address usdc, address stock, address adapter);
    event Filled(uint256 usdcIn, uint256 stockOut, uint256 minOut);
    event ProofOK(string what);

    function run() external {
        // Deployer/admin/user is a real EOA (default = anvil key #0 for gas-free
        // simulation; pass DEPLOYER_PK for a live broadcast). The attestor is a
        // throwaway hot key here (real deploys register the CRE attestor pubkey).
        uint256 deployerPk = vm.envOr(
            "DEPLOYER_PK",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        uint256 attestorPk = vm.envOr("ATTESTOR_PK", uint256(0xA11CE00000000000000000000000000000000000000000000000000000000001));
        address attestor = vm.addr(attestorPk);
        address me = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        // 1. Router (admin = deployer, Permit2 disabled → plain executeSwap path).
        IntentRouter router = new IntentRouter(me, address(0));
        router.setAttestor(attestor, true);
        // sdmToken left unset → tier checks disabled; feeBps 0 → no protocol fee.

        // 2. Tokens: USDC (6-dec) + a stand-in Stock Token (18-dec, "tNVDA").
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 stock = new MockERC20("Tokenized NVIDIA", "tNVDA", 18);

        // 3. Pool adapter @ $200/share, registered as a pure-swap venue.
        FixedRatePoolAdapter adapter = new FixedRatePoolAdapter(200);
        router.setVenue(VENUE, address(adapter), false);
        emit Deployed(address(router), address(usdc), address(stock), address(adapter));

        // 4. Seed adapter with Stock-Token liquidity; fund the user with USDC.
        stock.mint(address(adapter), 1_000_000e18);
        usdc.mint(me, 1_000e6);
        usdc.approve(address(router), type(uint256).max);

        // 5. Build the intent: pay 100 USDC → receive ~0.5 tNVDA. minOut = 0.49.
        SwapIntent memory intent = SwapIntent({
            user: me,
            tokenIn: address(usdc),
            tokenOut: address(stock),
            amountIn: 100e6,
            minOut: 0.49e18,
            deadline: block.timestamp + 600,
            venue: VENUE,
            nonce: 1,
            extra: "",
            bridgeFeeAmount: 0,
            sdmTier: 0
        });

        // 6. Attestor signs the EIP-712 intent digest (domain = this router, chainId 46630).
        bytes32 digest = router.hashIntent(intent);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // 7. Execute + prove the fill.
        uint256 before = stock.balanceOf(me);
        uint256 out = router.executeSwap(intent, sig, "");
        uint256 got = stock.balanceOf(me) - before;

        emit Filled(100e6, got, intent.minOut);
        require(got == out, "reported != delivered");
        require(got >= intent.minOut, "below minOut");
        require(got == 0.5e18, "unexpected fill amount");
        emit ProofOK("signed intent filled against the Stock-Token pool on RH Chain");

        vm.stopBroadcast();
    }
}
