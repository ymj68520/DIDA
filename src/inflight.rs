//! In-Flight请求追踪器
//!
//! 防止TCP重传导致同一个 (src_ip, dst_ip) 被重复处理。
//! 使用存在性集合（Set），值可以是空单元类型 ()。

use std::net::IpAddr;
use std::time::Duration;
use moka::future::Cache;

/// In-Flight请求追踪器
pub struct InflightTracker {
    // Key: (src_ip, dst_ip), Value: ()
    inner: Cache<(IpAddr, IpAddr), ()>,
}

impl InflightTracker {
    /// 创建新的追踪器
    ///
    /// # Arguments
    /// * `max_capacity` - 最大追踪条目数
    pub fn new(max_capacity: usize) -> Self {
        let inner = Cache::builder()
            .max_capacity(max_capacity as u64)
            .time_to_live(Duration::from_secs(10)) // 10秒后自动清除
            .build();

        Self { inner }
    }

    /// 检查并插入
    ///
    /// 返回true表示成功插入（之前不存在），false表示已存在（重复请求）
    pub async fn try_insert(&self, src_ip: IpAddr, dst_ip: IpAddr) -> bool {
        let key = (src_ip, dst_ip);

        // 尝试插入，如果已存在则返回false
        if self.inner.get(&key).await.is_some() {
            false
        } else {
            self.inner.insert(key, ()).await;
            true
        }
    }

    /// 标记请求完成（移除追踪）
    pub async fn invalidate(&self, src_ip: IpAddr, dst_ip: IpAddr) {
        let key = (src_ip, dst_ip);
        self.inner.invalidate(&key).await;
    }

    /// 检查是否在追踪中
    pub async fn contains(&self, src_ip: IpAddr, dst_ip: IpAddr) -> bool {
        let key = (src_ip, dst_ip);
        self.inner.get(&key).await.is_some()
    }

    /// 获取当前追踪数量
    pub fn entry_count(&self) -> u64 {
        self.inner.entry_count()
    }
}
