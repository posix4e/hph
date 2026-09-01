// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Campaign} from "../src/Campaign.sol";
import {JobFactory} from "../src/JobFactory.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// Deploys one measurement-validated campaign.
///
/// Every parameter is read from the environment so a deployment is reproducible
/// from a recorded command rather than from edited source. Nothing here is
/// upgradeable and no admin is set: once deployed, the rules are the rules.
contract Deploy is Script {
    function run() external {
        // Bounds-checked rather than cast: a mistyped environment value would
        // otherwise truncate into a *different* asset or token index and deploy
        // a campaign that measures the wrong market, without ever failing.
        uint256 assetRaw = vm.envUint("HPH_ASSET");
        uint256 coreTokenRaw = vm.envUint("HPH_CORE_TOKEN");
        uint256 windowRaw = vm.envUint("HPH_WINDOW_SECONDS");
        require(assetRaw <= type(uint32).max, "asset out of range");
        require(coreTokenRaw <= type(uint64).max, "core token out of range");
        require(windowRaw <= type(uint64).max, "window out of range");

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 asset = uint32(assetRaw);
        address token = vm.envAddress("HPH_PAYOUT_TOKEN");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 coreToken = uint64(coreTokenRaw);
        uint256 divisor = vm.envUint("HPH_CORE_UNIT_DIVISOR");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 windowSeconds = uint64(windowRaw);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 start = uint64(block.timestamp);
        uint64 end = start + windowSeconds;

        vm.startBroadcast();
        // The only deployment that needs big blocks. Everything after is a clone.
        Campaign implementation = new Campaign();
        JobFactory factory = new JobFactory(address(implementation));
        Campaign campaign = factory.launch(asset, IERC20(token), coreToken, divisor, start, end);
        vm.stopBroadcast();

        console.log("implementation", address(implementation));
        console.log("factory", address(factory));
        console.log("campaign", address(campaign));
        console.log("window", start, "to", end);
    }
}
