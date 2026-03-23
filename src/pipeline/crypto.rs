//! 密码学验证模块
//!
//! 实现ECDSA签名验证：
//! - V₁：使用PK_Top验证Sig_Top（顶级权威对Cert_IP的签名）
//! - V₂：使用PK_Sub验证Sig_Sub（节点对IP||TxID的签名）

use std::net::IpAddr;
use alloy::primitives::FixedBytes;
use k256::ecdsa::{Signature, VerifyingKey};
use k256::sha2::{Sha256, Digest};

use crate::state::ChainRecord;

/// V₁验证：顶级权威背书校验
///
/// 验证内容：
/// 1. Sig_Top的有效性（PK_Top验签）
/// 2. Cert_IP未过期
/// 3. 目标IP属于Cert_IP.ip_prefix
///
/// # Arguments
/// * `pk_top` - 顶级权威公钥
/// * `record` - 链上记录（包含Cert_IP和Sig_Top）
/// * `target_ip` - 目标IP地址
///
/// # Returns
/// * `true` - 验证通过
/// * `false` - 验证失败
pub fn verify_v1(
    pk_top: &VerifyingKey,
    record: &ChainRecord,
    target_ip: IpAddr,
) -> bool {
    // 1. 验证Sig_Top（PK_Top验签）
    let cert_hash = compute_cert_ip_hash(&record.cert_ip);

    let signature = match Signature::from_slice(&record.sig_top) {
        Ok(sig) => sig,
        Err(_) => {
            tracing::warn!("Invalid Sig_Top format");
            return false;
        }
    };

    // 使用k256的signature verifier
    use k256::ecdsa::signature::Verifier;
    match pk_top.verify(&cert_hash[..], &signature) {
        Ok(_) => {},
        Err(_) => {
            tracing::warn!("Sig_Top verification failed");
            return false;
        }
    }

    // 2. 验证凭证未过期
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();

    if record.cert_ip.expiration_timestamp < now {
        tracing::warn!("Certificate expired");
        return false;
    }

    // 3. 验证IP归属
    if !verify_ip_in_prefix(target_ip, &record.cert_ip.ip_prefix) {
        tracing::warn!("IP not in authorized prefix");
        return false;
    }

    // 4. 验证凭证未吊销
    if record.cert_ip.is_revoked {
        tracing::warn!("Certificate revoked");
        return false;
    }

    true
}

/// V₂验证：节点控制权校验
///
/// 验证内容：
/// Sig_Sub的有效性（PK_Sub验签，证明节点持有SK_Sub）
///
/// # Arguments
/// * `pk_sub` - 节点公钥（从Cert_IP提取）
/// * `sig_sub` - 节点自签名（来自DNS TXT记录）
/// * `ip` - 目标IP地址
/// * `tx_id` - 交易ID
///
/// # Returns
/// * `true` - 验证通过
/// * `false` - 验证失败
pub fn verify_v2(
    pk_sub: &VerifyingKey,
    sig_sub: &[u8],
    ip: IpAddr,
    tx_id: FixedBytes<32>,
) -> bool {
    // 计算消息哈希：IP || TxID
    let message_hash = compute_ip_txid_hash(ip, tx_id);

    let signature = match Signature::from_slice(sig_sub) {
        Ok(sig) => sig,
        Err(_) => {
            tracing::warn!("Invalid Sig_Sub format");
            return false;
        }
    };

    // 使用k256的signature verifier
    use k256::ecdsa::signature::Verifier;
    match pk_sub.verify(&message_hash[..], &signature) {
        Ok(_) => {},
        Err(_) => {
            tracing::warn!("Sig_Sub verification failed");
            return false;
        }
    }

    true
}

/// 计算Cert_IP的哈希（被签名对象）
fn compute_cert_ip_hash(cert_ip: &crate::state::CertIP) -> [u8; 32] {
    // TODO: 实现与Solidity keccak256(abi.encode(certIP))等价的哈希
    // 这里先用SHA256作为占位符
    let mut hasher = Sha256::new();

    // 哈希IP前缀
    hasher.update(cert_ip.ip_prefix.to_string().as_bytes());

    // 哈希公钥
    let pk_bytes = cert_ip.public_key.to_sec1_bytes();
    hasher.update(&pk_bytes);

    // 哈希过期时间
    hasher.update(cert_ip.expiration_timestamp.to_be_bytes());

    // 哈希吊销状态
    hasher.update([if cert_ip.is_revoked { 1 } else { 0 }]);

    hasher.finalize().into()
}

/// 计算IP || TxID的哈希（V₂的被签名对象）
fn compute_ip_txid_hash(ip: IpAddr, tx_id: FixedBytes<32>) -> [u8; 32] {
    let mut hasher = Sha256::new();

    // 哈希IP地址
    match ip {
        IpAddr::V4(addr) => hasher.update(addr.octets()),
        IpAddr::V6(addr) => hasher.update(addr.octets()),
    }

    // 哈希TxID
    hasher.update(tx_id.as_slice());

    hasher.finalize().into()
}

/// 验证IP是否属于指定的前缀
fn verify_ip_in_prefix(ip: IpAddr, prefix: &ipnet::IpNet) -> bool {
    prefix.contains(&ip)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ipnet::{IpNet, Ipv4Net};
    use std::net::Ipv4Addr;

    #[test]
    fn test_verify_ip_in_prefix() {
        let prefix_v4 = Ipv4Net::new(Ipv4Addr::new(192, 168, 1, 0), 24).unwrap();
        let prefix: IpNet = prefix_v4.into();
        let ip_in = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 100));
        let ip_out = IpAddr::V4(Ipv4Addr::new(192, 168, 2, 100));

        assert!(verify_ip_in_prefix(ip_in, &prefix));
        assert!(!verify_ip_in_prefix(ip_out, &prefix));
    }
}
