//! 遥测和计时模块
//!
//! 为流水线的每个阶段提供纳秒级精度计时：
//! - DNS查询时延
//! - RPC查询时延
//! - V₁验签时延
//! - V₂验签时延
//! - 端到端总时延

use std::time::Instant;

/// 流水线计时器
#[derive(Debug, Clone)]
pub struct PipelineTimer {
    start_time: Instant,
    dns_end: Option<Instant>,
    rpc_end: Option<Instant>,
    v1_end: Option<Instant>,
    v2_end: Option<Instant>,

    dns_duration: Option<std::time::Duration>,
    rpc_duration: Option<std::time::Duration>,
    v1_duration: Option<std::time::Duration>,
    v2_duration: Option<std::time::Duration>,

    cache_hit: bool,
}

impl PipelineTimer {
    /// 启动计时器
    pub fn start() -> Self {
        Self {
            start_time: Instant::now(),
            dns_end: None,
            rpc_end: None,
            v1_end: None,
            v2_end: None,
            dns_duration: None,
            rpc_duration: None,
            v1_duration: None,
            v2_duration: None,
            cache_hit: false,
        }
    }

    /// 记录DNS查询完成
    pub fn record_dns(&mut self) {
        self.dns_end = Some(Instant::now());
        self.dns_duration = Some(self.dns_end.unwrap() - self.start_time);
    }

    /// 记录缓存命中
    pub fn record_cache_hit(&mut self) {
        self.cache_hit = true;
    }

    /// 记录RPC查询完成
    pub fn record_rpc(&mut self) {
        self.rpc_end = Some(Instant::now());
        if let Some(dns_end) = self.dns_end {
            self.rpc_duration = Some(self.rpc_end.unwrap() - dns_end);
        }
    }

    /// 记录V₁验签完成
    pub fn record_v1(&mut self) {
        self.v1_end = Some(Instant::now());
        if let Some(rpc_end) = self.rpc_end {
            self.v1_duration = Some(self.v1_end.unwrap() - rpc_end);
        }
    }

    /// 记录V₂验签完成
    pub fn record_v2(&mut self) {
        self.v2_end = Some(Instant::now());
        if let Some(v1_end) = self.v1_end {
            self.v2_duration = Some(self.v2_end.unwrap() - v1_end);
        }
    }

    /// 记录总时延
    pub fn record_total(&mut self) {
        let total = self.start_time.elapsed();
        tracing::debug!("⏱️  总时延: {:?}", total);
    }

    /// 导出为CSV格式
    pub fn to_csv(&self) -> String {
        format!(
            "{},{},{},{},{},{}\n",
            self.dns_duration.map(|d| d.as_nanos()).unwrap_or(0),
            self.cache_hit,
            self.rpc_duration.map(|d| d.as_nanos()).unwrap_or(0),
            self.v1_duration.map(|d| d.as_nanos()).unwrap_or(0),
            self.v2_duration.map(|d| d.as_nanos()).unwrap_or(0),
            self.start_time.elapsed().as_nanos()
        )
    }
}

/// 导出CSV表头
pub fn csv_header() -> &'static str {
    "dns_ns,cache_hit,rpc_ns,v1_ns,v2_ns,total_ns\n"
}
