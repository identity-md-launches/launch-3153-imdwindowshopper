// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {WindowShopperToken} from "../src/WindowShopperToken.sol";

/// @title Deploy script for WindowShopperToken
/// @notice Reference deployment for reviewers and local testing. The production launch is performed by
///         the IMD factory from the attested creation code; this script is not part of that path and
///         is never broadcast by a task. It reads no environment variables and takes no configuration:
///         the token has no constructor arguments, and whichever account broadcasts receives the supply.
contract DeployWindowShopperToken is Script {
    /// @notice Deploys the token. Separated from `run()` so tests can call it directly.
    /// @return token The deployed token; its whole supply belongs to the caller of this function.
    function deploy() public returns (WindowShopperToken token) {
        token = new WindowShopperToken();
    }

    /// @notice Broadcast entry point: deploys with the broadcasting account as the supply recipient.
    function run() external returns (WindowShopperToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
