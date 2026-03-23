//! 网关全局状态管理
//!
//! 提供所有组件共享的不可变状态，包括：
//! - 密钥材料（PK_Top）
//! - 缓存（证书缓存、In-flight追踪）
//! - 网络客户端（DNS resolver、RPC provider）
//! - 配置参数

use std::sync::Arc;
use std::time::Duration;

use alloy::primitives::Address;
use alloy::providers::ProviderBuilder;
use hickory_resolver::TokioAsyncResolver;
use k256::ecdsa::VerifyingKey;
use ipnet::IpNet;

use crate::cache::CertCache;
use crate::inflight::InflightTracker;

/// IP凭证主体（Cert_IP）——V₁的被验证对象
#[derive(Clone, Debug)]
pub struct CertIP {
    /// 被授权的IP前缀
    pub ip_prefix: IpNet,
    /// 凭证持有者公钥 PK_Sub（V₂使用）
    pub public_key: VerifyingKey,
    /// 凭证过期时间戳（Unix时间）
    pub expiration_timestamp: u64,
    /// 吊销状态
    pub is_revoked: bool,
}

/// 从链上拉取并在本地缓存的完整记录
#[derive(Clone, Debug)]
pub struct ChainRecord {
    /// 凭证主体
    pub cert_ip: CertIP,
    /// Sig_Top：顶级权威对 keccak256(cert_ip) 的签名
    pub sig_top: Vec<u8>,
}

/// 网关全局状态（线程安全，不可变）
pub struct GatewayState {
    /// 顶级权威公钥 PK_Top（本地预置，用于V₁验签）
    pub pk_top: VerifyingKey,

    /// 证书缓存（TxID → ChainRecord）
    pub cert_cache: CertCache,

    /// In-Flight Task Tracker：防TCP重传导致同一 (src_ip, dst_ip) 被重复处理
    /// 值为 () 的存在性集合，超时自动清除
    pub inflight: InflightTracker,

    /// DNS异步解析器
    pub dns_resolver: TokioAsyncResolver,

    /// 区块链RPC Provider（HTTP + 连接池复用）
    pub rpc_provider: alloy::providers::ReqwestProvider,

    /// 合约地址（已解析为 alloy Address 类型）
    pub contract_address: Address,

    /// 最大并发连接数
    pub max_conns: usize,

    /// DNS查询超时时间
    pub dns_timeout: Duration,

    /// RPC查询超时时间
    pub rpc_timeout: Duration,
}

impl GatewayState {
    /// 创建新的网关状态
    ///
    /// # Arguments
    /// * `config_dir` - 配置文件目录
    /// * `enable_dns_cache` - 是否启用DNS缓存
    /// * `max_conns` - 最大并发连接数
    /// * `dns_server` - DNS服务器IP地址（可选）
    pub async fn new(
        config_dir: &str,
        _enable_dns_cache: bool,
        max_conns: usize,
        dns_server: Option<String>,
    ) -> Result<Arc<Self>, color_eyre::Report> {
        // 1. 加载PK_Top（本地预置，不依赖网络）
        let pk_top = Self::load_pk_top(config_dir)?;

        // 2. 加载合约配置
        let (contract_address, rpc_url, config_dns_server) = Self::load_contract_config(config_dir)?;

        // 3. 初始化DNS resolver
        let dns_resolver = Self::create_dns_resolver(dns_server.or(config_dns_server))?;

        // 4. 初始化RPC provider
        let rpc_provider = ProviderBuilder::new().on_http(rpc_url.parse()?);

        // 5. 初始化缓存
        let cert_cache = CertCache::new(max_conns);
        let inflight = InflightTracker::new(max_conns);

        // 6. 创建状态实例
        let state = Self {
            pk_top,
            cert_cache,
            inflight,
            dns_resolver,
            rpc_provider,
            contract_address,
            max_conns,
            dns_timeout: Duration::from_millis(50),
            rpc_timeout: Duration::from_millis(200),
        };

        Ok(Arc::new(state))
    }

    /// 创建DNS解析器
    fn create_dns_resolver(dns_server: Option<String>) -> Result<TokioAsyncResolver, color_eyre::Report> {
        use hickory_resolver::config::{ResolverConfig, ResolverOpts};
        
        match dns_server {
            Some(server) => {
                // 创建自定义DNS配置，指向树莓派IP
                let mut config = ResolverConfig::new();
                let socket_addr = format!("{}:53", server).parse()
                    .map_err(|e| color_eyre::eyre::eyre!("Invalid DNS server address: {}", e))?;
                
                config.add_name_server(hickory_resolver::config::NameServerConfig {
                    socket_addr,
                    protocol: hickory_resolver::config::Protocol::Udp,
                    tls_dns_name: None,
                    trust_negative_responses: false,
                    bind_addr: None,
                });
                
                let opts = ResolverOpts::default();
                Ok(TokioAsyncResolver::tokio(config, opts))
            }
            None => {
                // 使用系统配置（向后兼容）
                Ok(TokioAsyncResolver::tokio_from_system_conf()?)
            }
        }
    }

    /// 从配置文件加载PK_Top
    fn load_pk_top(config_dir: &str) -> Result<VerifyingKey, color_eyre::Report> {
        use std::fs;
        use std::path::Path;

        let trust_anchor_path = Path::new(config_dir).join("trust_anchor.env");

        if !trust_anchor_path.exists() {
            return Err(color_eyre::eyre::eyre!(
                "PK_Top配置文件不存在: {}",
                trust_anchor_path.display()
            ));
        }

        let contents = fs::read_to_string(trust_anchor_path)?;
        let pk_top_hex = contents
            .lines()
            .find(|line| line.starts_with("PK_TOP="))
            .map(|line| line.trim_start_matches("PK_TOP=").trim())
            .ok_or_else(|| color_eyre::eyre::eyre!("未找到PK_TOP配置项"))?;

        if pk_top_hex.is_empty() {
            return Err(color_eyre::eyre::eyre!("PK_TOP为空，请先运行密钥生成脚本"));
        }

        // 解析十六进制公钥（65字节非压缩格式）
        let pk_top_bytes = hex::decode(pk_top_hex.trim_start_matches("0x"))
            .map_err(|e| color_eyre::eyre::eyre!("Failed to decode PK_Top: {}", e))?;

        let pk_top = VerifyingKey::from_sec1_bytes(&pk_top_bytes)
            .map_err(|e| color_eyre::eyre::eyre!("Failed to parse PK_Top: {}", e))?;

        tracing::info!("✅ PK_Top已加载: {}...{}", &pk_top_hex[..16], &pk_top_hex[pk_top_hex.len()-16..]);

        Ok(pk_top)
    }

    /// 从配置文件加载合约配置
    fn load_contract_config(config_dir: &str) -> Result<(Address, String, Option<String>), color_eyre::Report> {
        use std::fs;
        use std::path::Path;

        let contract_env = Path::new(config_dir).join("contract.env");

        if !contract_env.exists() {
            return Err(color_eyre::eyre::eyre!(
                "合约配置文件不存在: {}",
                contract_env.display()
            ));
        }

        let contents = fs::read_to_string(contract_env)?;
        let mut contract_addr = None;
        let mut rpc_url = None;
        let mut dns_server = None;

        for line in contents.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }

            if let Some((key, value)) = line.split_once('=') {
                match key.trim() {
                    "CONTRACT_ADDR" => {
                        contract_addr = Some(value.trim().parse()
                            .map_err(|e| color_eyre::eyre::eyre!("Invalid CONTRACT_ADDR: {}", e))?);
                    }
                    "RPC_URL" => {
                        rpc_url = Some(value.trim().to_string());
                    }
                    "DNS_SERVER" => {
                        dns_server = Some(value.trim().to_string());
                    }
                    _ => {}
                }
            }
        }

        let contract_address = contract_addr
            .ok_or_else(|| color_eyre::eyre::eyre!("未找到CONTRACT_ADDR配置项"))?;

        let rpc_url = rpc_url.unwrap_or_else(|| "http://127.0.0.1:8545".to_string());

        if let Some(dns) = &dns_server {
            tracing::info!("✅ 合约配置已加载: {} @ {} (DNS: {})", contract_address, rpc_url, dns);
        } else {
            tracing::info!("✅ 合约配置已加载: {} @ {}", contract_address, rpc_url);
        }

        Ok((contract_address, rpc_url, dns_server))
    }
}
