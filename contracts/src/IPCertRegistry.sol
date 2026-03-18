// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPCertRegistry
 * @notice 存储 IP 凭证（Cert_IP）与顶级权威授权签名（Sig_Top）
 *         TxID -> ChainRecord 的扁平映射，单次 eth_call 返回完整凭证
 * @dev 实施计划 M2 阶段核心合约
 */
contract IPCertRegistry {

    // ── 凭证主体（Cert_IP），V1 验签的被签名对象 ──
    struct CertIP {
        string  ipPrefix;       // 被授权的 IP 前缀，如 "192.168.1.0/24"
        bytes   publicKey;      // 凭证持有者公钥 PK_Sub（secp256k1，65字节非压缩）
        uint64  expiration;     // 凭证过期 Unix 时间戳
        bool    isRevoked;      // 吊销状态位
    }

    // ── 链上完整记录 ──
    struct ChainRecord {
        CertIP  certIP;   // 凭证主体（被签名对象）
        bytes   sigTop;   // 顶级权威对 keccak256(abi.encode(certIP)) 的授权签名 Sig_Top
    }

    // TxID (bytes32) => 完整链上记录
    mapping(bytes32 => ChainRecord) public registry;

    // 权威管理员地址（实验阶段为合约部署者）
    address public immutable authority;

    // ── 事件（供网关 WebSocket 订阅）──
    event CertRegistered(bytes32 indexed txId, string ipPrefix);
    event Revoked(bytes32 indexed txId);

    constructor() {
        authority = msg.sender;
    }

    modifier onlyAuthority() {
        require(msg.sender == authority, "Not authorized");
        _;
    }

    /**
     * @notice 注册 IP 凭证（管理面，需顶级权威账户调用）
     * @param txId   32字节哈希指针（由 keccak256(ipPrefix + nonce) 生成，确保唯一性）
     * @param certIP 凭证主体
     * @param sigTop 顶级权威对 keccak256(abi.encode(certIP)) 的签名
     */
    function registerCert(
        bytes32        txId,
        CertIP calldata certIP,
        bytes  calldata sigTop
    ) external onlyAuthority {
        require(bytes(certIP.ipPrefix).length > 0, "Empty ipPrefix");
        require(certIP.publicKey.length == 65,      "Invalid publicKey length");
        require(certIP.expiration > block.timestamp, "Already expired");
        require(sigTop.length > 0,                   "Missing sigTop");

        registry[txId] = ChainRecord({ certIP: certIP, sigTop: sigTop });
        emit CertRegistered(txId, certIP.ipPrefix);
    }

    /**
     * @notice 批量注册凭证（Gas优化）
     */
    function registerCertBatch(
        bytes32[] calldata txIds,
        CertIP[] calldata certIPs,
        bytes[] calldata sigTops
    ) external onlyAuthority {
        require(txIds.length == certIPs.length, "Length mismatch");
        require(certIPs.length == sigTops.length, "Length mismatch");

        for (uint256 i = 0; i < txIds.length; i++) {
            require(bytes(certIPs[i].ipPrefix).length > 0, "Empty ipPrefix");
            require(certIPs[i].publicKey.length == 65, "Invalid publicKey length");
            require(certIPs[i].expiration > block.timestamp, "Already expired");
            require(sigTops[i].length > 0, "Missing sigTop");

            registry[txIds[i]] = ChainRecord({ certIP: certIPs[i], sigTop: sigTops[i] });
            emit CertRegistered(txIds[i], certIPs[i].ipPrefix);
        }
    }

    /**
     * @notice 吊销凭证（管理面）
     */
    function revokeCert(bytes32 txId) external onlyAuthority {
        require(bytes(registry[txId].certIP.ipPrefix).length > 0, "Record not found");
        registry[txId].certIP.isRevoked = true;
        emit Revoked(txId);
    }

    /**
     * @notice 数据面只读查询（网关调用 eth_call）
     */
    function getRecord(bytes32 txId) external view returns (ChainRecord memory) {
        return registry[txId];
    }

    /**
     * @notice 批量查询（Gas优化）
     */
    function getRecords(bytes32[] calldata txIds) external view returns (ChainRecord[] memory) {
        ChainRecord[] memory records = new ChainRecord[](txIds.length);
        for (uint256 i = 0; i < txIds.length; i++) {
            records[i] = registry[txIds[i]];
        }
        return records;
    }

    /**
     * @notice 检查凭证是否存在且有效
     */
    function isValid(bytes32 txId) external view returns (bool) {
        ChainRecord memory record = registry[txId];
        return bytes(record.certIP.ipPrefix).length > 0 &&
               !record.certIP.isRevoked &&
               record.certIP.expiration > block.timestamp;
    }
}
