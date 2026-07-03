// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockAggregator} from "../src/kit/MockAggregator.sol";

interface Vm {
    function addr(uint256 pk) external returns (address);
    function startBroadcast(uint256 pk) external;
    function stopBroadcast() external;
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256);
}

/// @title Deploy Chainlink-compatible reference feeds for the listed markets.
///        Prices in 8-dec USD: TSLA $300, AMD $150, AMZN $200 (match the seeded
///        pool spot so honest quotes pass; tighten/mismatch to demo a reject).
///
///   forge script script/DeployFeeds.s.sol --rpc-url rh_testnet --broadcast --slow
contract DeployFeeds {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    event Feed(string symbol, address feed, int256 priceUsd8);

    function run() external {
        uint256 pk = vm.envOr(
            "DEPLOYER_PK",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        vm.startBroadcast(pk);
        _feed("TSLA", 300e8);
        _feed("AMD", 150e8);
        _feed("AMZN", 200e8);
        vm.stopBroadcast();
    }

    function _feed(string memory sym, int256 priceUsd8) internal {
        MockAggregator f = new MockAggregator(priceUsd8, string.concat(sym, " / USD"));
        emit Feed(sym, address(f), priceUsd8);
    }
}
