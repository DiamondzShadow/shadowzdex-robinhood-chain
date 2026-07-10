// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IntentRouter} from "../src/shadowz/IntentRouter.sol";
import {UniswapV2Adapter} from "../src/shadowz/adapters/UniswapV2Adapter.sol";

interface Vm {
    function addr(uint256 pk) external returns (address);
    function startBroadcast(uint256 pk) external;
    function stopBroadcast() external;
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256);
    function envAddress(string calldata name) external returns (address);
    function envAddress(string calldata name, string calldata delim) external returns (address[] memory);
    function envString(string calldata name, string calldata delim) external returns (string[] memory);
}

interface IUniV2FactoryMin {
    function allPairsLength() external view returns (uint256);
}

/// @title Mainnet wiring — register the UniswapV2Adapter on a LIVE IntentRouter.
///
/// Robinhood Chain mainnet (chain 4663) ships real V2-style AMMs — Uniswap +
/// Rialto (the proprietary prop-trading AMM). This deploys the production
/// `UniswapV2Adapter` bound to the already-deployed mainnet IntentRouter,
/// whitelists each venue's real router, and registers a venue key per DEX.
/// Every address comes from env — nothing is hardcoded — and each is validated
/// on-chain before anything is written:
///   • INTENT_ROUTER must be a deployed contract, and the broadcaster must hold
///     its CONFIG_ROLE (else setVenue would revert anyway — we fail fast + clear).
///   • every V2 router must have code AND answer factory() != 0 (i.e. actually
///     be a Uniswap-V2 router — guards against a fat-fingered address).
///   • ADMIN (the adapter's role admin — use the per-chain Safe) must be nonzero.
///
/// Config (env):
///   DEPLOYER_PK    uint    broadcaster key (must hold CONFIG_ROLE on the router)
///   INTENT_ROUTER  address live mainnet IntentRouter
///   ADMIN          address adapter role admin — the mainnet Safe
///   V2_ROUTERS     address[] comma-separated real routers to whitelist (Uniswap, Rialto)
///   VENUE_KEYS     string[]  comma-separated venue names to register → the adapter
///                            (e.g. "UNISWAP_V2,RIALTO_V2"); each resolves to this
///                            one adapter, the specific pool comes from adapterData.
///
///   forge script script/DeployMainnetUniV2.s.sol --fork-url rh_mainnet -vvvv        # dry-run
///   forge script script/DeployMainnetUniV2.s.sol --rpc-url rh_mainnet --broadcast --slow
contract DeployMainnetUniV2 {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    event AdapterDeployed(address adapter, address intentRouter, address admin, uint256 factories);
    event FactoryWhitelisted(address factory, uint256 allPairsLength);
    event VenueRegistered(string key, bytes32 venue, address adapter);

    error NotAContract(address a);
    error NotAFactory(address factory);
    error MissingConfigRole(address caller);
    error NoFactories();
    error NoVenues();
    error ZeroAdmin();

    function run() external {
        uint256 pk = vm.envOr("DEPLOYER_PK", uint256(0));
        require(pk != 0, "DEPLOYER_PK env var is required");
        address me = vm.addr(pk);

        address intentRouter = vm.envAddress("INTENT_ROUTER");
        address admin = vm.envAddress("ADMIN");
        address[] memory factories = vm.envAddress("V2_FACTORIES", ",");
        string[] memory venueKeys = vm.envString("VENUE_KEYS", ",");

        // ── Validate, before writing anything ──
        if (intentRouter.code.length == 0) revert NotAContract(intentRouter);
        if (admin == address(0)) revert ZeroAdmin();
        if (factories.length == 0) revert NoFactories();
        if (venueKeys.length == 0) revert NoVenues();

        IntentRouter router = IntentRouter(intentRouter);
        // Broadcaster must hold CONFIG_ROLE, or setVenue reverts on-chain.
        if (!router.hasRole(router.CONFIG_ROLE(), me)) revert MissingConfigRole(me);

        for (uint256 i = 0; i < factories.length; i++) {
            address f = factories[i];
            if (f.code.length == 0) revert NotAContract(f);
            // A real UniV2 factory answers allPairsLength() (guards against a
            // fat-fingered address that happens to have code).
            try IUniV2FactoryMin(f).allPairsLength() returns (uint256) {}
            catch {
                revert NotAFactory(f);
            }
        }

        // ── Deploy + wire ──
        vm.startBroadcast(pk);

        UniswapV2Adapter adapter = new UniswapV2Adapter(intentRouter, factories, admin);
        emit AdapterDeployed(address(adapter), intentRouter, admin, factories.length);
        for (uint256 i = 0; i < factories.length; i++) {
            emit FactoryWhitelisted(factories[i], IUniV2FactoryMin(factories[i]).allPairsLength());
        }

        for (uint256 i = 0; i < venueKeys.length; i++) {
            bytes32 venue = keccak256(bytes(venueKeys[i]));
            router.setVenue(venue, address(adapter), false);
            emit VenueRegistered(venueKeys[i], venue, address(adapter));
        }

        vm.stopBroadcast();
    }
}
