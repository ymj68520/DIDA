// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/IPCertRegistry.sol";

contract DeployScript is Script {
    IPCertRegistry public registry;

    function run() external {
        // 使用Anvil的默认账户（私钥：0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80）
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        vm.startBroadcast(deployerPrivateKey);

        // 部署合约
        registry = new IPCertRegistry();

        console.log("IPCertRegistry deployed at:", address(registry));

        vm.stopBroadcast();
    }
}
