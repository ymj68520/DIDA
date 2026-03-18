// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/IPCertRegistry.sol";

contract DeployScript is Script {
    IPCertRegistry public registry;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("SK_TOP");
        vm.startBroadcast(deployerPrivateKey);

        // 部署合约
        registry = new IPCertRegistry();

        console.log("IPCertRegistry deployed at:", address(registry));

        vm.stopBroadcast();
    }
}
