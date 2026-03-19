//! DIDA认证网关错误类型
//!
//! 定义所有可能的错误类型，提供清晰的错误信息和上下文

use std::net::IpAddr;

/// DIDA网关错误类型
#[derive(Debug, thiserror::Error)]
pub enum DidaError {
    /// DNS查询相关错误
    #[error("DNS查询失败: {0}")]
    DnsQueryFailed(String),

    #[error("DNS查询超时")]
    DnsTimeout,

    #[error("DNS记录格式错误: {0}")]
    DnsRecordInvalid(String),

    /// RPC查询相关错误
    #[error("RPC查询失败: {0}")]
    RpcQueryFailed(String),

    #[error("RPC查询超时")]
    RpcTimeout,

    #[error("合约调用失败: {0}")]
    ContractCallFailed(String),

    /// 密码学验证相关错误
    #[error("V₁验证失败: IP {ip} 不匹配证书前缀 {prefix}")]
    V1VerificationFailed { ip: IpAddr, prefix: String },

    #[error("V₂验证失败: IP {ip} 的签名无效")]
    V2VerificationFailed { ip: IpAddr },

    #[error("签名解析失败: {0}")]
    SignatureParseFailed(String),

    #[error("公钥解析失败: {0}")]
    PublicKeyParseFailed(String),

    /// 缓存相关错误
    #[error("缓存操作失败: {0}")]
    CacheError(String),

    /// 配置相关错误
    #[error("配置文件加载失败: {0}")]
    ConfigLoadFailed(String),

    #[error("环境变量未设置: {0}")]
    EnvVarMissing(String),

    /// Netfilter相关错误
    #[error("Netfilter queue操作失败: {0}")]
    NfqError(String),

    #[error("报文解析失败: {0}")]
    PacketParseError(String),

    /// IO错误
    #[error("IO错误: {0}")]
    IoError(#[from] std::io::Error),

    /// 序列化错误
    #[error("JSON序列化失败: {0}")]
    JsonError(#[from] serde_json::Error),

    /// 其他错误
    #[error("未知错误: {0}")]
    Unknown(String),
}

/// DIDA网关Result类型
pub type DidaResult<T> = Result<T, DidaError>;

impl DidaError {
    /// 创建DNS查询失败错误
    pub fn dns_query_failed(msg: impl Into<String>) -> Self {
        Self::DnsQueryFailed(msg.into())
    }

    /// 创建RPC查询失败错误
    pub fn rpc_query_failed(msg: impl Into<String>) -> Self {
        Self::RpcQueryFailed(msg.into())
    }

    /// 创建V₁验证失败错误
    pub fn v1_verification_failed(ip: IpAddr, prefix: impl Into<String>) -> Self {
        Self::V1VerificationFailed {
            ip,
            prefix: prefix.into(),
        }
    }

    /// 创建V₂验证失败错误
    pub fn v2_verification_failed(ip: IpAddr) -> Self {
        Self::V2VerificationFailed { ip }
    }

    /// 检查错误是否可重试
    pub fn is_retryable(&self) -> bool {
        matches!(self, Self::DnsTimeout | Self::RpcTimeout)
    }

    /// 检查错误是否应该导致报文丢弃
    pub fn should_drop_packet(&self) -> bool {
        matches!(
            self,
            Self::DnsTimeout | Self::RpcTimeout | Self::V1VerificationFailed { .. } | Self::V2VerificationFailed { .. }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_creation() {
        let err = DidaError::dns_query_failed("测试错误");
        assert_eq!(err.to_string(), "DNS查询失败: 测试错误");
    }

    #[test]
    fn test_error_retryable() {
        assert!(DidaError::DnsTimeout.is_retryable());
        assert!(DidaError::RpcTimeout.is_retryable());
        assert!(!DidaError::V1VerificationFailed {
            ip: IpAddr::V4(std::net::Ipv4Addr::new(192, 168, 1, 1)),
            prefix: "192.168.1.0/24".to_string()
        }
        .is_retryable());
    }

    #[test]
    fn test_should_drop_packet() {
        assert!(DidaError::DnsTimeout.should_drop_packet());
        assert!(DidaError::V2VerificationFailed {
            ip: IpAddr::V4(std::net::Ipv4Addr::new(192, 168, 1, 1))
        }
        .should_drop_packet());
    }
}
