// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IntentRouter} from "../src/shadowz/IntentRouter.sol";
import {InventoryFillerAdapter} from "../src/shadowz/adapters/InventoryFillerAdapter.sol";

interface Vm {
    function addr(uint256 pk) external returns (address);
    function startBroadcast(uint256 pk) external;
    function stopBroadcast() external;
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256);
    function envAddress(string calldata name) external returns (address);
    function envAddress(string calldata name, string calldata delim) external returns (address[] memory);
    function envString(string calldata name) external returns (string memory);
    function envUint(string calldata name) external returns (uint256);
}

interface IAggregatorV3Min {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @title Mainnet wiring — register the InventoryFillerAdapter on a LIVE IntentRouter.
///
/// The real day-one venue on Robinhood Chain mainnet (chain 4663): an oracle-priced
/// RFQ / solver fill from market-maker inventory, since public equity AMM liquidity
/// is still nascent. Deploys the production `InventoryFillerAdapter` bound to the
/// already-live mainnet IntentRouter, seeds its book with each Stock Token ↔ real
/// Chainlink feed in the SAME transaction (so DEFAULT_ADMIN_ROLE goes straight to
/// the Safe — the deployer never needs a role on the adapter), and registers a
/// single venue key. Every address comes from env; each is validated on-chain
/// before anything is written:
///   • INTENT_ROUTER must be a deployed contract and the broadcaster must hold its
///     CONFIG_ROLE (else setVenue reverts anyway — we fail fast + clear).
///   • QUOTE (USDG) and every STOCK must have code.
///   • every FEED must have code, answer latestRoundData() with a positive price,
///     and be fresh within MAX_STALENESS (a dead/stale feed can't be listed).
///   • ADMIN (adapter role admin — the per-chain Safe) must be nonzero.
///
/// The adapter deploys EMPTY of inventory. It is NON-CUSTODIAL of user funds but
/// holds the market-maker's book: after this script, the treasurer (Safe) funds it
/// with USDG + Stock Tokens via `deposit()` / a plain transfer. No fills succeed
/// until inventory exists (transfers revert cleanly), so registering the venue
/// before funding is safe.
///
/// Config (env / .env.mainnet):
///   DEPLOYER_PK   uint     broadcaster key (must hold CONFIG_ROLE on the router)
///   INTENT_ROUTER address  live mainnet IntentRouter
///   ADMIN         address  adapter role admin — the mainnet Safe
///   QUOTE         address  shared quote token — USDG
///   FILLER_STOCKS address[] comma-separated Stock Tokens to list
///   FILLER_FEEDS  address[] comma-separated Chainlink feeds (parallel to STOCKS)
///   FILLER_SPREAD_BPS uint  MM spread withheld from oracle-fair output (<= 1000)
///   FILLER_MAX_STALENESS uint feed staleness ceiling, seconds (e.g. 86400)
///   FILLER_VENUE_KEY  string venue name to register (e.g. "SHADOWZ_RFQ")
///
///   forge script script/DeployFillerMainnet.s.sol --fork-url rh_mainnet -vvvv        # dry-run
///   forge script script/DeployFillerMainnet.s.sol --rpc-url rh_mainnet --broadcast --slow
contract DeployFillerMainnet {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    event FillerDeployed(address adapter, address intentRouter, address quote, address admin, uint256 markets);
    event MarketWired(address stock, address feed, int256 priceUsd);
    event VenueRegistered(string key, bytes32 venue, address adapter);

    error NotAContract(address a);
    error DeadFeed(address feed);
    error StaleFeed(address feed, uint256 age);
    error MissingConfigRole(address caller);
    error NoMarkets();
    error LengthMismatch();
    error ZeroAdmin();
    error SpreadTooHigh(uint256 bps);

    function run() external {
        uint256 pk = vm.envOr("DEPLOYER_PK", uint256(0));
        require(pk != 0, "DEPLOYER_PK env var is required");
        address me = vm.addr(pk);

        address intentRouter = vm.envAddress("INTENT_ROUTER");
        address admin = vm.envAddress("ADMIN");
        address quote = vm.envAddress("QUOTE");
        address[] memory stocks = vm.envAddress("FILLER_STOCKS", ",");
        address[] memory feeds = vm.envAddress("FILLER_FEEDS", ",");
        uint256 spreadBps = vm.envUint("FILLER_SPREAD_BPS");
        uint256 maxStaleness = vm.envUint("FILLER_MAX_STALENESS");
        string memory venueKey = vm.envString("FILLER_VENUE_KEY");

        // ── Validate, before writing anything ──
        if (intentRouter.code.length == 0) revert NotAContract(intentRouter);
        if (admin == address(0)) revert ZeroAdmin();
        if (quote.code.length == 0) revert NotAContract(quote);
        if (stocks.length == 0) revert NoMarkets();
        if (stocks.length != feeds.length) revert LengthMismatch();
        if (spreadBps > 1000) revert SpreadTooHigh(spreadBps);

        IntentRouter router = IntentRouter(intentRouter);
        if (!router.hasRole(router.CONFIG_ROLE(), me)) revert MissingConfigRole(me);

        for (uint256 i = 0; i < stocks.length; i++) {
            if (stocks[i].code.length == 0) revert NotAContract(stocks[i]);
            address feed = feeds[i];
            if (feed.code.length == 0) revert NotAContract(feed);
            (, int256 answer,, uint256 updatedAt,) = IAggregatorV3Min(feed).latestRoundData();
            if (answer <= 0) revert DeadFeed(feed);
            uint256 age = block.timestamp - updatedAt;
            if (age > maxStaleness) revert StaleFeed(feed, age);
        }

        // ── Deploy + wire (atomic: markets seeded, admin = Safe) ──
        vm.startBroadcast(pk);

        InventoryFillerAdapter adapter =
            new InventoryFillerAdapter(intentRouter, quote, admin, uint16(spreadBps), maxStaleness, stocks, feeds);
        emit FillerDeployed(address(adapter), intentRouter, quote, admin, stocks.length);
        for (uint256 i = 0; i < stocks.length; i++) {
            (, int256 answer,,,) = IAggregatorV3Min(feeds[i]).latestRoundData();
            emit MarketWired(stocks[i], feeds[i], answer);
        }

        bytes32 venue = keccak256(bytes(venueKey));
        router.setVenue(venue, address(adapter), false);
        emit VenueRegistered(venueKey, venue, address(adapter));

        vm.stopBroadcast();
    }
}
