//! 证书缓存模块
//!
//! 基于moka的高性能并发缓存，支持：
//! - TTL过期
//! - 基于容量的LRU淘汰
//! - 异步刷新

use std::hash::Hash;
use std::sync::Arc;
use moka::future::Cache;
use alloy::primitives::FixedBytes;

use crate::state::ChainRecord;

/// 证书缓存（TxID → ChainRecord）
pub struct CertCache {
    inner: Cache<FixedBytes<32>, Arc<ChainRecord>>,
}

impl CertCache {
    /// 创建新的证书缓存
    ///
    /// # Arguments
    /// * `max_capacity` - 最大缓存条目数
    pub fn new(max_capacity: usize) -> Self {
        let inner = Cache::builder()
            .max_capacity(max_capacity as u64)
            .time_to_live(std::time::Duration::from_secs(300)) // 5分钟TTL
            .time_to_idle(std::time::Duration::from_secs(60))  // 1分钟空闲淘汰
            .build();

        Self { inner }
    }

    /// 获取缓存记录
    pub async fn get(&self, tx_id: &FixedBytes<32>) -> Option<Arc<ChainRecord>> {
        self.inner.get(tx_id).await
    }

    /// 插入缓存记录
    pub async fn insert(&self, tx_id: FixedBytes<32>, record: Arc<ChainRecord>) {
        self.inner.insert(tx_id, record).await;
    }

    /// 使缓存记录失效
    pub async fn invalidate(&self, tx_id: &FixedBytes<32>) {
        self.inner.invalidate(tx_id).await;
    }

    /// 清空所有缓存
    pub fn invalidate_all(&self) {
        self.inner.invalidate_all();
    }

    /// 获取缓存统计信息
    pub fn stats(&self) -> CacheStats {
        let entry_count = self.inner.entry_count();
        CacheStats {
            hit_count: 0, // moka cache doesn't expose hit/miss counts directly
            miss_count: 0,
            total_count: entry_count as u64,
            hit_rate: 0.0,
        }
    }
}

/// 缓存统计信息
#[derive(Debug, Clone)]
pub struct CacheStats {
    pub hit_count: u64,
    pub miss_count: u64,
    pub total_count: u64,
    pub hit_rate: f64,
}

impl std::fmt::Display for CacheStats {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "CacheStats{{hits={}, misses={}, hit_rate={:.2}%}}",
            self.hit_count,
            self.miss_count,
            self.hit_rate * 100.0
        )
    }
}
