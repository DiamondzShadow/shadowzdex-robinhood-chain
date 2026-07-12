// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UniswapV3Adapter} from "../src/shadowz/adapters/UniswapV3Adapter.sol";

interface Vm {
    function addr(uint256 pk) external returns (address);
    function startBroadcast(uint256 pk) external;
    function stopBroadcast() external;
    function envUint(string calldata name) external returns (uint256);
    function envAddress(string calldata name) external returns (address);
}

/// @title Mainnet wiring — deploy the UniswapV3Adapter for a LIVE IntentRouter.
///
/// Robinhood Chain mainnet (chain 4663) now carries real concentrated liquidity:
/// the WETH/USDG 0.05% Uniswap V3 pool holds ~$1M and quotes within 0.0% of the
/// Chainlink ETH/USD feed. This adapter routes user intents straight into that
/// live book — NON-CUSTODIAL, holds zero inventory of its own (unlike the
/// InventoryFillerAdapter). Every address comes from env and is validated on-chain
/// before the adapter is deployed:
///   • INTENT_ROUTER    must be a deployed contract (the live router the adapter binds to).
///   • V3_SWAP_ROUTER   (Uniswap SwapRouter02) must have code — it is the ONLY router
///                      whitelisted at construction.
///   • ADMIN            (the per-chain Safe) must be nonzero — it receives
///                      DEFAULT_ADMIN / CONFIG / RESCUER; the deployer never gets a role.
///
/// Deploy does NOT register the venue: the live router is Safe-owned, so
/// `setVenue(keccak256("UNISWAP_V3"), <adapter>, false)` is a separate Safe
/// transaction (this script logs the adapter address + that calldata for it).
///
///   forge script script/DeployUniV3AdapterMainnet.s.sol --rpc-url rh_mainnet -vvvv          # dry-run
///   forge script script/DeployUniV3AdapterMainnet.s.sol --rpc-url rh_mainnet --broadcast --slow
contract DeployUniV3AdapterMainnet {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    event AdapterDeployed(address adapter, address router, address v3SwapRouter, address admin);

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address router = vm.envAddress("INTENT_ROUTER");
        address v3SwapRouter = vm.envAddress("V3_SWAP_ROUTER");
        address admin = vm.envAddress("ADMIN");

        require(_hasCode(router), "INTENT_ROUTER has no code");
        require(_hasCode(v3SwapRouter), "V3_SWAP_ROUTER has no code");
        require(admin != address(0), "ADMIN is zero");

        address[] memory allowed = new address[](1);
        allowed[0] = v3SwapRouter;

        vm.startBroadcast(deployerPk);
        UniswapV3Adapter adapter = new UniswapV3Adapter(router, allowed, admin);
        vm.stopBroadcast();

        // Sanity: constructor wiring landed as intended.
        require(adapter.ROUTER() == router, "ROUTER mismatch");
        require(adapter.allowedRouter(v3SwapRouter), "SwapRouter02 not whitelisted");
        require(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), admin), "admin role not on Safe");

        emit AdapterDeployed(address(adapter), router, v3SwapRouter, admin);

        // The Safe must now execute, on `router`:
        //   setVenue(keccak256("UNISWAP_V3"), address(adapter), false)
    }

    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }
}
