//! Exp-5 压测客户端：完整 TCP 三次握手并发认证
//!
//! 功能：
//! - 发起完整TCP三次握手（SYN → SYN-ACK → ACK）
//! - 记录每次连接的成功/失败和时延
//! - 支持可配置的并发度和持续时间
//! - 输出TPS和时延P50/P95/P99统计
//!
//! 用法：
//!   cargo run --bin load_client -- \
//!     --target 192.168.1.100:80 \
//!     --concurrency 1000 \
//!     --duration 30 \
//!     --output results/exp5/raw.csv

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use clap::Parser;
use color_eyre::Result;

/// 压测客户端命令行参数
#[derive(Parser, Debug)]
#[command(name = "load_client")]
#[command(author = "DIDA Research Team")]
#[command(version = "0.1.0")]
struct Args {
    /// 目标服务器地址（格式：IP:PORT）
    #[arg(long)]
    target: SocketAddr,

    /// 并发连接数
    #[arg(long, default_value = "100")]
    concurrency: usize,

    /// 测试持续时间（秒）
    #[arg(long, default_value = "30")]
    duration: u64,

    /// 输出CSV文件路径
    #[arg(long, default_value = "results/exp5/raw.csv")]
    output: String,

    /// 连接超时时间（毫秒）
    #[arg(long, default_value = "5000")]
    timeout_ms: u64,

    /// 是否在连接后发送数据（模拟真实流量）
    #[arg(long, default_value = "false")]
    send_data: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    color_eyre::install()?;
    let args = Args::parse();

    println!("🚀 Exp-5 压测客户端");
    println!("   目标: {}", args.target);
    println!("   并发度: {}", args.concurrency);
    println!("   持续时间: {}s", args.duration);
    println!("   超时: {}ms", args.timeout_ms);
    println!("   发送数据: {}", args.send_data);
    println!("   输出: {}", args.output);
    println!();

    // 统计计数器
    let success = Arc::new(AtomicU64::new(0));
    let failure = Arc::new(AtomicU64::new(0));
    let timeout_count = Arc::new(AtomicU64::new(0));

    // 时延记录（使用Vec预分配内存）
    let latencies = Arc::new(Mutex::new(Vec::with_capacity(
        args.concurrency * (args.duration as usize) * 10,
    )));

    let deadline = Instant::now() + Duration::from_secs(args.duration);
    let connect_timeout = Duration::from_millis(args.timeout_ms);

    println!("⏱️  开始压测...");

    // 创建指定并发度的tokio任务
    let mut handles = Vec::with_capacity(args.concurrency);
    for worker_id in 0..args.concurrency {
        let target = args.target;
        let success = success.clone();
        let failure = failure.clone();
        let timeout_count = timeout_count.clone();
        let lats = latencies.clone();
        let send_data = args.send_data;

        handles.push(tokio::spawn(async move {
            let mut local_success = 0u64;
            let mut local_failure = 0u64;
            let mut local_timeout = 0u64;
            let start_time = Instant::now();

            while Instant::now() < deadline {
                let t0 = Instant::now();

                // 完整 TCP 三次握手（connect = SYN → SYN-ACK → ACK）
                match tokio::time::timeout(connect_timeout, TcpStream::connect(target)).await {
                    Ok(Ok(stream)) => {
                        let lat_ms = t0.elapsed().as_secs_f64() * 1000.0;

                        // 可选：发送少量数据模拟真实流量
                        if send_data {
                            let _ = stream.try_write(b"GET / HTTP/1.1\r\n\r\n");
                        }

                        local_success += 1;
                        lats.lock().await.push(lat_ms);

                        // 立即关闭连接（发送FIN）
                        drop(stream);
                    }
                    Ok(Err(_)) => {
                        local_failure += 1;
                    }
                    Err(_) => {
                        // Timeout
                        local_timeout += 1;
                    }
                }

                // 小延迟避免CPU 100%占用
                tokio::time::sleep(Duration::from_micros(100)).await;

                // 第一个worker定期输出进度
                if worker_id == 0 {
                    let elapsed = start_time.elapsed().as_secs();
                    if elapsed > 0 && elapsed.is_multiple_of(10) {
                        println!("   [Worker-0] 已运行 {}s，成功: {}", elapsed, local_success);
                    }
                }
            }

            // 更新全局统计
            success.fetch_add(local_success, Ordering::Relaxed);
            failure.fetch_add(local_failure, Ordering::Relaxed);
            timeout_count.fetch_add(local_timeout, Ordering::Relaxed);
        }));
    }

    // 等待所有worker完成
    for handle in handles {
        handle.await?;
    }

    println!("✅ 压测完成");
    println!();

    // ── 统计分析 ───────────────────────────────────────────────
    let lats_snapshot = latencies.lock().await.clone();
    let total_success = success.load(Ordering::Relaxed);
    let total_failure = failure.load(Ordering::Relaxed);
    let total_timeout = timeout_count.load(Ordering::Relaxed);
    let total_attempts = total_success + total_failure + total_timeout;

    let tps = if args.duration > 0 {
        total_success as f64 / args.duration as f64
    } else {
        0.0
    };

    // 计算时延百分位数
    let mut sorted = lats_snapshot.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let p50 = sorted.get(sorted.len() / 2).copied().unwrap_or(0.0);
    let p95 = sorted.get(sorted.len() * 95 / 100).copied().unwrap_or(0.0);
    let p99 = sorted.get(sorted.len() * 99 / 100).copied().unwrap_or(0.0);

    let avg = if !sorted.is_empty() {
        sorted.iter().sum::<f64>() / sorted.len() as f64
    } else {
        0.0
    };

    // ── 输出结果 ───────────────────────────────────────────────
    println!("📊 Exp-5 压测结果");
    println!("═══════════════════════════════════════");
    println!("   并发度:        {}", args.concurrency);
    println!("   持续时间:      {}s", args.duration);
    println!("   总尝试次数:    {}", total_attempts);
    println!("   ✅ 成功:       {} ({:.1}%)", total_success,
        percentage(total_success, total_attempts));
    println!("   ❌ 失败:       {} ({:.1}%)", total_failure,
        percentage(total_failure, total_attempts));
    println!("   ⏱️  超时:       {} ({:.1}%)", total_timeout,
        percentage(total_timeout, total_attempts));
    println!();
    println!("   吞吐量 (TPS):  {:.2}", tps);
    println!();
    println!("   时延统计:");
    println!("     平均值:      {:.2} ms", avg);
    println!("     P50:         {:.2} ms", p50);
    println!("     P95:         {:.2} ms", p95);
    println!("     P99:         {:.2} ms", p99);
    println!("═══════════════════════════════════════");
    println!();

    // ── 写入CSV ─────────────────────────────────────────────────
    if !lats_snapshot.is_empty() {
        println!("💾 写入CSV数据到: {}", args.output);

        // 创建输出目录
        if let Some(parent) = std::path::Path::new(&args.output).parent() {
            std::fs::create_dir_all(parent)?;
        }

        // 写入时延数据
        let mut w = csv::Writer::from_path(&args.output)?;
        w.write_record(["latency_ms"])?;
        for lat in &lats_snapshot {
            w.write_record(&[format!("{:.4}", lat)])?;
        }
        w.flush()?;

        // 写入统计摘要
        let summary_path = args.output.replace(".csv", "_summary.txt");
        let mut summary = std::fs::File::create(&summary_path)?;
        use std::io::Write;

        writeln!(summary, "Exp-5 压测摘要")?;
        writeln!(summary, "═══════════════════════════════════════")?;
        writeln!(summary, "测试时间:       {}", chrono::Utc::now().format("%Y-%m-%d %H:%M:%S UTC"))?;
        writeln!(summary, "目标地址:       {}", args.target)?;
        writeln!(summary, "并发度:         {}", args.concurrency)?;
        writeln!(summary, "持续时间:       {}s", args.duration)?;
        writeln!(summary, "总尝试次数:     {}", total_attempts)?;
        writeln!(summary, "成功次数:       {}", total_success)?;
        writeln!(summary, "失败次数:       {}", total_failure)?;
        writeln!(summary, "超时次数:       {}", total_timeout)?;
        writeln!(summary, "TPS:            {:.2}", tps)?;
        writeln!(summary, "平均时延:       {:.2} ms", avg)?;
        writeln!(summary, "P50时延:        {:.2} ms", p50)?;
        writeln!(summary, "P95时延:        {:.2} ms", p95)?;
        writeln!(summary, "P99时延:        {:.2} ms", p99)?;
        writeln!(summary, "═══════════════════════════════════════")?;

        println!("💾 摘要已写入: {}", summary_path);
    }

    Ok(())
}

/// 计算百分比
fn percentage(count: u64, total: u64) -> f64 {
    if total == 0 {
        0.0
    } else {
        (count as f64 / total as f64) * 100.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_percentage() {
        assert_eq!(percentage(50, 100), 50.0);
        assert_eq!(percentage(0, 100), 0.0);
        assert_eq!(percentage(100, 100), 100.0);
        assert_eq!(percentage(1, 3), 33.33333333333333);
    }
}
