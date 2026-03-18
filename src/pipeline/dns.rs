//! DNS查询模块
//!
//! 通过rDNS查询获取TxID和Sig_Sub：
//! - 查询格式：IP.in-addr.arpa TXT
//! - 返回格式："v1|<tx_id>|<sig_sub>"

use std::net::IpAddr;
use alloy::primitives::FixedBytes;
use color_eyre::Result;

use crate::state::GatewayState;

/// 查询rDNS TXT记录
///
/// # Arguments
/// * `state` - 网关状态
/// * `ip` - 目标IP地址
///
/// # Returns
/// * `Ok((tx_id, sig_sub))` - 查询成功
/// * `Err` - 查询失败
pub async fn query_txt(
    state: &GatewayState,
    ip: IpAddr,
) -> Result<(FixedBytes<32>, Vec<u8>), color_eyre::Report> {
    // 构造反向DNS查询名称
    let reverse_name = reverse_dns_name(ip)?;

    tracing::debug!("🔍 DNS查询: {}", reverse_name);

    // 执行DNS查询
    let response = state.dns_resolver.txt_lookup(reverse_name.as_str()).await
        .map_err(|e| color_eyre::eyre::eyre!("DNS lookup failed: {}", e))?;

    // 解析TXT记录
    let txt_record = response.iter().next()
        .ok_or_else(|| color_eyre::eyre::eyre!("No TXT record found"))?;

    let txt_data = txt_record.to_string();
    tracing::debug!("📄 TXT记录: {}", txt_data);

    // 解析TXT记录格式: "v1|<tx_id>|<sig_sub>"
    let parts: Vec<&str> = txt_data.split('|').collect();
    if parts.len() != 3 || parts[0] != "v1" {
        return Err(color_eyre::eyre::eyre!("Invalid TXT record format"));
    }

    let tx_id_hex = parts[1].trim();
    let sig_sub_hex = parts[2].trim();

    // 解析TxID（32字节）
    let tx_id_bytes = hex::decode(tx_id_hex.trim_start_matches("0x"))
        .map_err(|e| color_eyre::eyre::eyre!("Invalid TxID hex: {}", e))?;

    if tx_id_bytes.len() != 32 {
        return Err(color_eyre::eyre::eyre!("TxID must be 32 bytes"));
    }

    let mut tx_id = FixedBytes::<32>::default();
    tx_id.copy_from_slice(&tx_id_bytes);

    // 解析Sig_Sub
    let sig_sub = hex::decode(sig_sub_hex.trim_start_matches("0x"))
        .map_err(|e| color_eyre::eyre::eyre!("Invalid Sig_Sub: {}", e))?;

    Ok((tx_id, sig_sub))
}

/// 将IP地址转换为反向DNS查询名称
///
/// # Example
/// ```
/// assert_eq!(reverse_dns_name("192.168.1.100"), Ok("100.1.168.192.in-addr.arpa".to_string()));
/// ```
fn reverse_dns_name(ip: IpAddr) -> Result<String, color_eyre::Report> {
    match ip {
        IpAddr::V4(addr) => {
            let octets = addr.octets();
            let reversed = octets.iter().rev()
                .map(|o| o.to_string())
                .collect::<Vec<_>>()
                .join(".");

            Ok(format!("{}.in-addr.arpa", reversed))
        }
        IpAddr::V6(_addr) => {
            // TODO: 实现IPv6反向DNS
            Err(color_eyre::eyre::eyre!("IPv6 reverse DNS not implemented"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn test_reverse_dns_name() {
        let ip = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 100));
        let result = reverse_dns_name(ip).unwrap();
        assert_eq!(result, "100.1.168.192.in-addr.arpa");
    }
}
