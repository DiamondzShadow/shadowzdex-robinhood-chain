// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IntentRouter} from "../src/shadowz/IntentRouter.sol";

interface Vm {
    function addr(uint256 pk) external returns (address);
    function startBroadcast(uint256 pk) external;
    function stopBroadcast() external;
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256);
    function envOr(string calldata name, bool defaultValue) external returns (bool);
    function envOr(string calldata name, address defaultValue) external returns (address);
    function envAddress(string calldata name) external returns (address);
}

interface ISafe {
    function getThreshold() external view returns (uint256);
}

/// @title Mainnet DeployProve — deploy the PRODUCTION ShadowzDex IntentRouter on
///        Robinhood Chain mainnet (chain 4663) and hand it to the Safe.
///
/// The testnet DeployProve deploys the router and proves a fill against a mock
/// pool. On mainnet there are no mocks: this deploys the real router, registers
/// the CRE attestor, sets the fee policy, and transfers every admin role to the
/// mainnet Safe. The "proof" is configuration correctness — asserted at the end —
/// plus a live EIP-712 domain bound to chainId 4663. Real swaps come once the
/// UniswapV2Adapter is wired (script/DeployMainnetUniV2.s.sol) against real pools.
///
/// Sequence:
///   1. this script          → router live, attestor + fee set, Safe = admin
///   2. DeployMainnetUniV2    → adapter + venues (needs deployer CONFIG_ROLE, so
///                              run BEFORE renouncing — keep RENOUNCE_DEPLOYER=false here)
///   3. re-run this with RENOUNCE_DEPLOYER=true (or renounce via the Safe) to drop
///      the deployer's roles once wiring is done.
///
/// Config (env):
///   DEPLOYER_PK        uint    broadcaster key
///   ADMIN              address mainnet Safe — receives every admin role (must have code)
///   ATTESTOR           address CRE attestor pubkey to authorize as a signer
///   PERMIT2            address Permit2 (default 0 = disable the Permit2 path)
///   FEE_BPS            uint    protocol fee on swaps (default 0; ceiling 100 = 1%)
///   FEE_TREASURY       address fee sink if FEE_BPS>0 (default = ADMIN)
///   PASS_DISCOUNT_BPS  uint    ShadowPass fee discount (default 0)
///   RENOUNCE_DEPLOYER  bool    renounce deployer's roles after handoff (default false)
///
///   forge script script/DeployProveMainnet.s.sol --fork-url rh_mainnet -vvvv        # dry-run
///   forge script script/DeployProveMainnet.s.sol --rpc-url rh_mainnet --broadcast --slow
contract DeployProveMainnet {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    event RouterDeployed(address router, address admin, address permit2, uint256 chainId);
    event AttestorSet(address attestor);
    event FeeSet(uint16 feeBps, uint16 passDiscountBps, address treasury);
    event AdminHandoff(address safe, bool deployerRenounced);
    event SafeThresholdUnverified(address admin); // ADMIN has code but isn't a Safe (Timelock/other)
    event ProofOK(string what);

    error ZeroAttestor();
    error AdminNotContract(address admin);

    function run() external {
        uint256 pk = vm.envOr("DEPLOYER_PK", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address me = vm.addr(pk);

        address admin = vm.envAddress("ADMIN");
        address attestor = vm.envAddress("ATTESTOR");
        address permit2 = vm.envOr("PERMIT2", address(0));
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(0));
        uint256 passDiscountBps = vm.envOr("PASS_DISCOUNT_BPS", uint256(0));
        address feeTreasury = vm.envOr("FEE_TREASURY", admin);
        bool renounce = vm.envOr("RENOUNCE_DEPLOYER", false);

        // ── Validate before deploying ──
        if (attestor == address(0)) revert ZeroAttestor();
        if (admin.code.length == 0) revert AdminNotContract(admin); // Safe must be a deployed contract

        vm.startBroadcast(pk);

        // 1. Router — deployer is temporary admin so this script can configure it.
        IntentRouter router = new IntentRouter(me, permit2);
        emit RouterDeployed(address(router), admin, permit2, block.chainid);

        // 2. Authorize the CRE attestor as an intent signer.
        router.setAttestor(attestor, true);
        emit AttestorSet(attestor);

        // 3. Fee policy (default 0 → no protocol fee; setFee reverts if treasury == 0).
        if (feeBps > 0) {
            router.setFee(uint16(feeBps), uint16(passDiscountBps), feeTreasury);
            emit FeeSet(uint16(feeBps), uint16(passDiscountBps), feeTreasury);
        }

        // 4. Hand every admin role to the Safe. Best-effort Safe sanity check.
        try ISafe(admin).getThreshold() returns (uint256 t) {
            require(t > 0, "safe threshold 0");
        } catch {
            emit SafeThresholdUnverified(admin); // not a Gnosis Safe — allowed (Timelock/other), but flagged
        }
        _grant(router, router.DEFAULT_ADMIN_ROLE(), admin);
        _grant(router, router.CONFIG_ROLE(), admin);
        _grant(router, router.PAUSER_ROLE(), admin);
        _grant(router, router.RESCUER_ROLE(), admin);
        _grant(router, router.SIGNER_ADMIN_ROLE(), admin);

        // 5. Optionally drop the deployer's roles. Default false so the next step
        //    (adapter wiring) can still use the deployer's CONFIG_ROLE. Renounce
        //    DEFAULT_ADMIN last so earlier renounces stay authorized.
        if (renounce) {
            router.renounceRole(router.CONFIG_ROLE(), me);
            router.renounceRole(router.PAUSER_ROLE(), me);
            router.renounceRole(router.RESCUER_ROLE(), me);
            router.renounceRole(router.SIGNER_ADMIN_ROLE(), me);
            router.renounceRole(router.DEFAULT_ADMIN_ROLE(), me);
        }
        emit AdminHandoff(admin, renounce);

        // 6. Prove the end state.
        require(router.isAttestor(attestor), "attestor not registered");
        require(router.hasRole(router.DEFAULT_ADMIN_ROLE(), admin), "safe lacks admin");
        require(router.hasRole(router.CONFIG_ROLE(), admin), "safe lacks config");
        if (renounce) {
            require(!router.hasRole(router.DEFAULT_ADMIN_ROLE(), me), "deployer still admin");
            require(!router.hasRole(router.CONFIG_ROLE(), me), "deployer still config");
        }
        emit ProofOK("IntentRouter live on RH Chain mainnet: attestor registered, Safe = admin");

        vm.stopBroadcast();
    }

    function _grant(IntentRouter router, bytes32 role, address to) internal {
        if (!router.hasRole(role, to)) router.grantRole(role, to);
    }
}
