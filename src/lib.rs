//! DIDA认证网关库
//!
//! 提供双重身份DNS锚定认证的核心功能：
//! - Netfilter报文拦截
//! - DNS和区块链查询
//! - 双重ECDSA签名验证
//! - 缓存和去重机制

pub mod error;
pub mod state;
pub mod cache;
pub mod inflight;
pub mod telemetry;
pub mod pipeline;
pub mod nfq;
pub mod whitelist;

pub use error::{DidaError, DidaResult};

// 重新导出常用类型
pub use state::GatewayState;
pub use telemetry::PipelineTimer;
pub use telemetry::csv_header;

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_library_imports() {
        // 测试库的基本导入功能
        assert_eq!(csv_header(), "dns_ns,cache_hit,rpc_ns,v1_ns,v2_ns,total_ns\n");
    }
}
