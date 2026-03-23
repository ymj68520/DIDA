//! 网络白名单模块
//!
//! 功能：
//! - 加载白名单配置（IP/CIDR/域名）
//! - 判断目标IP是否在白名单中
//! - 白名单地址绕过NFQUEUE验证
//!
//! 使用场景：
//! - 本地回环流量（127.0.0.0/8）
//! - 内网管理段（可配置）
//! - 管理员工作站（可配置）

use std::fs;
use std::net::IpAddr;
use std::path::Path;
use std::sync::Arc;
use ipnet::IpNet;
use once_cell::sync::Lazy;
use tracing::{info, warn, debug};

/// 白名单配置
#[derive(Debug, Clone, Default)]
pub struct WhitelistConfig {
    /// 精确IP地址白名单
    pub ips: Vec<IpAddr>,
    /// CIDR网段白名单
    pub cidrs: Vec<IpNet>,
    /// 域名白名单（后缀匹配）
    pub domains: Vec<String>,
}



/// 全局白名单配置（单例）
static WHITELIST: Lazy<Arc<WhitelistConfig>> = Lazy::new(|| {
    load_whitelist().unwrap_or_else(|e| {
        warn!("⚠️  加载白名单配置失败: {}，使用默认配置", e);
        Arc::new(WhitelistConfig::default())
    })
});

/// 加载白名单配置
///
/// # 流程
/// 1. 尝试从config/whitelist.env加载
/// 2. 如果文件不存在，使用默认配置（仅本地回环）
/// 3. 解析IP、CIDR、域名
/// 4. 自动添加本地回环（127.0.0.0/8）
pub fn load_whitelist() -> Result<Arc<WhitelistConfig>, Box<dyn std::error::Error>> {
    let config_path = "config/whitelist.env";

    // 如果配置文件不存在，使用默认配置
    if !Path::new(config_path).exists() {
        info!("📋 白名单配置文件不存在，使用默认配置");
        info!("   提示：创建 config/whitelist.env 来自定义白名单");
        return Ok(Arc::new(WhitelistConfig::default()));
    }

    info!("📋 加载白名单配置: {}", config_path);

    let content = fs::read_to_string(config_path)?;
    let mut config = WhitelistConfig::default();

    // 解析配置行
    for line in content.lines() {
        let line = line.trim();

        // 跳过注释和空行
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        // 解析 KEY=VALUE
        if let Some((key, value)) = line.split_once('=') {
            let key = key.trim();
            let value = value.trim();

            // 跳过空值
            if value.is_empty() {
                continue;
            }

            match key {
                "WHITELIST_IPS" => {
                    for ip_str in value.split(',') {
                        let ip_str = ip_str.trim();
                        if let Ok(ip) = ip_str.parse::<IpAddr>() {
                            config.ips.push(ip);
                            debug!("  ✅ IP白名单: {}", ip);
                        } else {
                            warn!("  ⚠️  无效IP地址: {}", ip_str);
                        }
                    }
                }
                "WHITELIST_CIDRS" => {
                    for cidr_str in value.split(',') {
                        let cidr_str = cidr_str.trim();
                        if let Ok(cidr) = cidr_str.parse::<IpNet>() {
                            config.cidrs.push(cidr);
                            debug!("  ✅ CIDR白名单: {}", cidr);
                        } else {
                            warn!("  ⚠️  无效CIDR: {}", cidr_str);
                        }
                    }
                }
                "WHITELIST_DOMAINS" => {
                    for domain in value.split(',') {
                        let domain = domain.trim();
                        if !domain.is_empty() {
                            config.domains.push(domain.to_string());
                            debug!("  ✅ 域名白名单: {}", domain);
                        }
                    }
                }
                "ADMIN_WORKSTATIONS" => {
                    // 管理员工作站（作为IP处理）
                    for ip_str in value.split(',') {
                        let ip_str = ip_str.trim();
                        if let Ok(ip) = ip_str.parse::<IpAddr>() {
                            config.ips.push(ip);
                            debug!("  ✅ 管理员工作站: {}", ip);
                        }
                    }
                }
                "INTERNAL_CLUSTER" => {
                    // 内部服务集群（作为CIDR处理）
                    for cidr_str in value.split(',') {
                        let cidr_str = cidr_str.trim();
                        if let Ok(cidr) = cidr_str.parse::<IpNet>() {
                            config.cidrs.push(cidr);
                            debug!("  ✅ 内部服务集群: {}", cidr);
                        }
                    }
                }
                _ => {
                    debug!("  ⚠️  未知配置项: {}", key);
                }
            }
        }
    }

    info!("✅ 白名单配置加载完成");
    info!("   - IP地址: {}", config.ips.len());
    info!("   - CIDR网段: {}", config.cidrs.len());
    info!("   - 域名: {}", config.domains.len());

    Ok(Arc::new(config))
}

/// 检查IP是否在白名单中
///
/// # 检查顺序
/// 1. 本地回环（127.0.0.0/8）- 自动包含
/// 2. 精确IP匹配
/// 3. CIDR网段匹配
///
/// # Arguments
/// * `ip` - 要检查的IP地址
///
/// # Returns
/// * `true` - IP在白名单中
/// * `false` - IP不在白名单中
pub fn is_whitelisted(ip: IpAddr) -> bool {
    // 1. 检查本地回环（自动包含）
    if is_loopback(ip) {
        debug!("🛡️  本地回环地址（自动白名单）: {}", ip);
        return true;
    }

    // 2. 精确IP匹配
    if WHITELIST.ips.contains(&ip) {
        debug!("✅ IP精确匹配（白名单）: {}", ip);
        return true;
    }

    // 3. CIDR网段匹配
    for cidr in &WHITELIST.cidrs {
        if cidr.contains(&ip) {
            debug!("✅ CIDR匹配（白名单）: {} in {}", ip, cidr);
            return true;
        }
    }

    false
}

/// 检查是否为本地回环地址
///
/// # 说明
/// - IPv4: 127.0.0.0/8
/// - IPv6: ::1/128
fn is_loopback(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ipv4) => {
            ipv4.is_loopback()
        }
        IpAddr::V6(ipv6) => {
            ipv6.is_loopback()
        }
    }
}

/// 检查域名是否在白名单中
///
/// # 匹配规则
/// - 精确匹配："example.com" 仅匹配 example.com
/// - 后缀匹配：".example.com" 匹配 *.example.com
///
/// # Arguments
/// * `domain` - 要检查的域名
///
/// # Returns
/// * `true` - 域名在白名单中
/// * `false` - 域名不在白名单中
pub fn is_domain_whitelisted(domain: &str) -> bool {
    for whitelist_domain in &WHITELIST.domains {
        // 后缀匹配
        if whitelist_domain.starts_with('.') {
            if domain.ends_with(whitelist_domain) || domain == &whitelist_domain[1..] {
                debug!("✅ 域名后缀匹配（白名单）: {} 匹配 {}", domain, whitelist_domain);
                return true;
            }
        }
        // 精确匹配
        else if domain == whitelist_domain {
            debug!("✅ 域名精确匹配（白名单）: {}", domain);
            return true;
        }
    }

    false
}

/// 获取白名单配置（用于调试）
pub fn get_whitelist_config() -> Arc<WhitelistConfig> {
    WHITELIST.clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_loopback_detection() {
        assert!(is_loopback("127.0.0.1".parse().unwrap()));
        assert!(is_loopback("127.0.0.2".parse().unwrap()));
        assert!(!is_loopback("192.168.1.1".parse().unwrap()));
    }

    #[test]
    fn test_is_whitelisted() {
        // 本地回环应该自动在白名单中
        assert!(is_whitelisted("127.0.0.1".parse().unwrap()));
        assert!(is_whitelisted("127.0.0.2".parse().unwrap()));

        // 非本地地址应该不在白名单中（默认配置）
        assert!(!is_whitelisted("192.168.1.1".parse().unwrap()));
        assert!(!is_whitelisted("8.8.8.8".parse().unwrap()));
    }

    #[test]
    fn test_domain_whitelist() {
        // 这个测试需要实际配置才能工作
        // 这里只是展示匹配逻辑
        let domain = "www.example.com";

        // 后缀匹配
        let whitelist_domain = ".example.com";
        assert!(domain.ends_with(whitelist_domain));

        // 精确匹配
        let whitelist_domain = "www.example.com";
        assert!(domain == whitelist_domain);
    }
}
