// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/IPCertRegistry.sol";

contract IPCertRegistryTest is Test {
    IPCertRegistry registry;
    bytes32 constant TEST_TXID = keccak256("192.168.1.0/24:nonce:1");
    bytes32 constant TEST_TXID_2 = keccak256("10.0.0.0/8:nonce:2");

    // 测试用的公钥（非压缩格式，65字节）
    bytes constant TEST_PK_SUB = abi.encodePacked(
        bytes1(0x04),
        bytes32(uint256(1)),
        bytes32(uint256(2))
    );

    function setUp() public {
        registry = new IPCertRegistry();
    }

    function testRegisterAndQuery() public {
        IPCertRegistry.CertIP memory cert = IPCertRegistry.CertIP({
            ipPrefix:   "192.168.1.0/24",
            publicKey:  TEST_PK_SUB,
            expiration: uint64(block.timestamp + 365 days),
            isRevoked:  false
        });
        bytes memory fakeSigTop = abi.encodePacked(bytes32(uint256(0xdeadbeef)));

        registry.registerCert(TEST_TXID, cert, fakeSigTop);

        IPCertRegistry.ChainRecord memory record = registry.getRecord(TEST_TXID);
        assertEq(record.certIP.ipPrefix, "192.168.1.0/24");
        assertFalse(record.certIP.isRevoked);
        assertEq(record.sigTop, fakeSigTop);
    }

    function testRevocation() public {
        // 先注册
        IPCertRegistry.CertIP memory cert = IPCertRegistry.CertIP({
            ipPrefix: "10.0.0.0/8",
            publicKey: TEST_PK_SUB,
            expiration: uint64(block.timestamp + 86400),
            isRevoked: false
        });
        registry.registerCert(TEST_TXID, cert, new bytes(64));

        // 吊销
        registry.revokeCert(TEST_TXID);
        assertTrue(registry.getRecord(TEST_TXID).certIP.isRevoked);
    }

    function testOnlyAuthorityCanRegister() public {
        vm.prank(address(0x1234));
        vm.expectRevert("Not authorized");
        registry.registerCert(TEST_TXID,
            IPCertRegistry.CertIP("1.2.3.0/24", TEST_PK_SUB,
                uint64(block.timestamp + 1), false),
            new bytes(64));
    }

    function testInvalidPublicKeyLength() public {
        bytes memory shortKey = new bytes(64); // 应该是65字节
        vm.expectRevert("Invalid publicKey length");
        registry.registerCert(TEST_TXID,
            IPCertRegistry.CertIP("1.2.3.0/24", shortKey,
                uint64(block.timestamp + 1), false),
            new bytes(64));
    }

    function testEmptyIpPrefix() public {
        vm.expectRevert("Empty ipPrefix");
        registry.registerCert(TEST_TXID,
            IPCertRegistry.CertIP("", TEST_PK_SUB,
                uint64(block.timestamp + 1), false),
            new bytes(64));
    }

    function testAlreadyExpired() public {
        vm.expectRevert("Already expired");
        registry.registerCert(TEST_TXID,
            IPCertRegistry.CertIP("1.2.3.0/24", TEST_PK_SUB,
                uint64(block.timestamp - 1), false),
            new bytes(64));
    }

    function testMissingSigTop() public {
        vm.expectRevert("Missing sigTop");
        registry.registerCert(TEST_TXID,
            IPCertRegistry.CertIP("1.2.3.0/24", TEST_PK_SUB,
                uint64(block.timestamp + 1), false),
            new bytes(0));
    }

    function testBatchRegistration() public {
        IPCertRegistry.CertIP memory cert1 = IPCertRegistry.CertIP({
            ipPrefix: "192.168.1.0/24",
            publicKey: TEST_PK_SUB,
            expiration: uint64(block.timestamp + 365 days),
            isRevoked: false
        });

        IPCertRegistry.CertIP memory cert2 = IPCertRegistry.CertIP({
            ipPrefix: "10.0.0.0/8",
            publicKey: TEST_PK_SUB,
            expiration: uint64(block.timestamp + 365 days),
            isRevoked: false
        });

        bytes32[] memory txIds = new bytes32[](2);
        txIds[0] = TEST_TXID;
        txIds[1] = TEST_TXID_2;

        IPCertRegistry.CertIP[] memory certIPs = new IPCertRegistry.CertIP[](2);
        certIPs[0] = cert1;
        certIPs[1] = cert2;

        bytes[] memory sigTops = new bytes[](2);
        sigTops[0] = new bytes(64);
        sigTops[1] = new bytes(64);

        registry.registerCertBatch(txIds, certIPs, sigTops);

        assertEq(registry.getRecord(TEST_TXID).certIP.ipPrefix, "192.168.1.0/24");
        assertEq(registry.getRecord(TEST_TXID_2).certIP.ipPrefix, "10.0.0.0/8");
    }

    function testBatchRegistrationLengthMismatch() public {
        bytes32[] memory txIds = new bytes32[](2);
        IPCertRegistry.CertIP[] memory certIPs = new IPCertRegistry.CertIP[](1);

        vm.expectRevert("Length mismatch");
        registry.registerCertBatch(txIds, certIPs, new bytes[](1));
    }

    function testIsValid() public {
        IPCertRegistry.CertIP memory cert = IPCertRegistry.CertIP({
            ipPrefix: "192.168.1.0/24",
            publicKey: TEST_PK_SUB,
            expiration: uint64(block.timestamp + 365 days),
            isRevoked: false
        });

        registry.registerCert(TEST_TXID, cert, new bytes(64));
        assertTrue(registry.isValid(TEST_TXID));
    }

    function testIsNotValidWhenRevoked() public {
        IPCertRegistry.CertIP memory cert = IPCertRegistry.CertIP({
            ipPrefix: "192.168.1.0/24",
            publicKey: TEST_PK_SUB,
            expiration: uint64(block.timestamp + 365 days),
            isRevoked: false
        });

        registry.registerCert(TEST_TXID, cert, new bytes(64));
        registry.revokeCert(TEST_TXID);
        assertFalse(registry.isValid(TEST_TXID));
    }

    function testIsNotValidWhenExpired() public {
        IPCertRegistry.CertIP memory cert = IPCertRegistry.CertIP({
            ipPrefix: "192.168.1.0/24",
            publicKey: TEST_PK_SUB,
            expiration: uint64(block.timestamp - 1),
            isRevoked: false
        });

        registry.registerCert(TEST_TXID, cert, new bytes(64));
        assertFalse(registry.isValid(TEST_TXID));
    }

    function testIsNotValidWhenNotFound() public {
        assertFalse(registry.isValid(TEST_TXID));
    }
}
