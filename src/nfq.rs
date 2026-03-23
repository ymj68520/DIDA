//! Netfilter Queue报文拦截模块
//!
//! 功能：
//! - 创建并绑定Netfilter queue
//! - 拦截TCP SYN报文
//! - 提取源IP和目标IP
//! - 下发NF_ACCEPT或NF_DROP裁决

use std::sync::Arc;
use std::net::IpAddr;
use std::time::Duration;
use nfq::{Queue, Verdict, Message};
use tokio::signal;
use tracing::{info, error, warn, debug};
use color_eyre::Result;

use crate::pipeline::process_packet;
use crate::state::GatewayState;
use crate::whitelist;

/// nfq运行配置
pub struct NfqConfig {
    /// Netfilter队列号
    pub queue_num: u16,
    /// 报文处理超时
    pub _packet_timeout: Duration,
    /// CSV输出路径（None表示不输出CSV）
    pub _csv_output: Option<String>,
}

impl Default for NfqConfig {
    fn default() -> Self {
        Self {
            queue_num: 0,
            _packet_timeout: Duration::from_secs(5),
            _csv_output: None,
        }
    }
}

/// 启动nfq拦截器
///
/// # Arguments
/// * `config` - nfq配置
/// * `state` - 网关状态
///
/// # Returns
/// * `Ok(())` - 正常退出
/// * `Err` - 错误
pub async fn run_nfq_loop(
    config: NfqConfig,
    state: Arc<GatewayState>,
) -> Result<()> {
    info!("🔌 初始化Netfilter Queue...");
    info!("   队列号: {}", config.queue_num);

    // 打开Netfilter queue
    let mut queue = Queue::open()?;
    info!("✅ Queue 已打开");

    // 绑定队列
    queue.bind(config.queue_num)?;
    info!("✅ 队列已绑定到 {}", config.queue_num);

    info!("\n🚀 开始拦截报文...");
    info!("   拦截规则: TCP SYN报文");
    info!("   按 Ctrl+C 停止\n");

    let mut packet_count = 0;
    let mut accept_count = 0;
    let mut drop_count = 0;

    // 主循环
    loop {
        // 接收报文
        let mut msg = match queue.recv() {
            Ok(m) => m,
            Err(e) => {
                error!("❌ 接收报文失败: {}", e);
                continue;
            }
        };

        // 提取IP信息
        let (src_ip, dst_ip) = match extract_ips(&msg) {
            Some(ips) => ips,
            None => {
                warn!("⚠️  无法提取IP地址，丢弃报文");
                msg.set_verdict(Verdict::Drop);
                if let Err(e) = queue.verdict(msg) {
                    error!("❌ 下发裁决失败: {}", e);
                }
                continue;
            }
        };

        packet_count += 1;

        debug!("📦 [{}] {} -> {}", packet_count, src_ip, dst_ip);

        // 检查白名单（优先级最高）
        // 白名单地址直接通过，不进行验证
        if whitelist::is_whitelisted(dst_ip) {
            accept_count += 1;
            debug!("✅ 白名单地址（绕过验证）: {}", dst_ip);

            msg.set_verdict(Verdict::Accept);
            if let Err(e) = queue.verdict(msg) {
                error!("❌ 下发裁决失败: {}", e);
            }
            continue;
        }

        // 处理报文（异步验证流水线）
        let state_clone = state.clone();
        let should_accept = process_packet(state_clone, dst_ip, src_ip).await;

        // 记录统计
        if should_accept {
            accept_count += 1;
            debug!("✅ NF_ACCEPT: {} -> {}", src_ip, dst_ip);
        } else {
            drop_count += 1;
            debug!("❌ NF_DROP: {} -> {}", src_ip, dst_ip);
        }

        // 下发裁决
        let verdict = if should_accept {
            Verdict::Accept
        } else {
            Verdict::Drop
        };

        msg.set_verdict(verdict);
        if let Err(e) = queue.verdict(msg) {
            error!("❌ 下发裁决失败: {}", e);
        }

        // 定期输出统计
        if packet_count % 100 == 0 {
            info!("📊 统计: 总计={}, 接受={}, 拒绝={}",
                packet_count, accept_count, drop_count);
        }
    }
}

/// 从报文中提取源IP和目标IP
///
/// # Arguments
/// * `msg` - Netfilter消息对象
///
/// # Returns
/// * `Some((src_ip, dst_ip))` - 成功提取
/// * `None` - 提取失败
fn extract_ips(msg: &Message) -> Option<(IpAddr, IpAddr)> {
    use pnet::packet::ipv4::Ipv4Packet;

    // 获取报文数据
    let payload = msg.get_payload();

    // 解析IPv4报文
    let ipv4_packet = Ipv4Packet::new(payload)?;

    // 提取源和目标IP
    let src_ip = IpAddr::V4(ipv4_packet.get_source());
    let dst_ip = IpAddr::V4(ipv4_packet.get_destination());

    Some((src_ip, dst_ip))
}

/// 启动nfq拦截器的便捷函数
pub async fn start_nfq(state: Arc<GatewayState>, queue_num: u16) -> Result<()> {
    info!("📋 NFQUEUE模式说明:");
    info!("   - NFQUEUE规则由setup脚本配置");
    info!("   - 本地回环流量已排除（!-o lo, !-i lo）");
    info!("   - 白名单过滤在内部进行");
    info!("   - 退出时无需清理NFQUEUE规则");

    // 配置Ctrl+C处理
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    tokio::select! {
        _ = ctrl_c => {
            info!("\n⚠️  收到停止信号，正在退出...");
            info!("📊 最终统计将在主循环退出后显示");
            Ok(())
        }
        result = run_nfq_loop(NfqConfig {
            queue_num,
            ..Default::default()
        }, state) => {
            result
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_nfq_config_default() {
        let config = NfqConfig::default();
        assert_eq!(config.queue_num, 0);
    }
}
