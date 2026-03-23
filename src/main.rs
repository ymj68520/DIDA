//! DIDA认证网关主入口
//!
//! 功能：
//! - 拦截TCP SYN报文（通过Netfilter queue）
//! - 执行双重身份验证（V₁: 顶级权威背书，V₂: 节点控制权验证）
//! - 下发NF_ACCEPT或NF_DROP裁决
//!
//! 架构：
//! - I/O线程池：处理nfq报文、DNS查询、RPC调用
//! - 计算线程池：隔离密码学运算（ECDSA验签）
//! - 多级缓存：moka缓存 + WebSocket事件订阅

use clap::Parser;
use color_eyre::Result;
use tracing::{info, error, Level};
use tracing_subscriber::{FmtSubscriber, EnvFilter};

mod state;
mod cache;
mod inflight;
mod telemetry;
mod pipeline;
mod nfq;
mod ws_listener;
mod whitelist;

use state::GatewayState;

/// DIDA认证网关命令行参数
#[derive(Parser, Debug)]
#[command(name = "auth-gateway")]
#[command(author = "DIDA Research Team")]
#[command(version = "0.1.0")]
#[command(about = "Dual-Identity DNS-Anchored Authentication Gateway", long_about = None)]
struct Args {
    /// 运行模式：bypass（直通）、query-only（仅查询）、full（完整验证）
    #[arg(long, default_value = "full")]
    mode: String,

    /// Netfilter队列号
    #[arg(short, long, default_value_t = 0)]
    queue_num: u16,

    /// 配置文件目录
    #[arg(short, long, default_value = "config")]
    config_dir: String,

    /// 日志级别：trace, debug, info, warn, error
    #[arg(long, default_value = "info")]
    log_level: String,

    /// 是否启用DNS缓存
    #[arg(long, default_value_t = true)]
    dns_cache: bool,

    /// 最大并发连接数
    #[arg(long, default_value_t = 10000)]
    max_conns: usize,

    /// DNS服务器IP地址
    #[arg(long, default_value = "")]
    dns_server: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    // 初始化错误处理
    color_eyre::install()?;

    // 解析命令行参数
    let args = Args::parse();

    // 初始化日志
    let log_level = match args.log_level.as_str() {
        "trace" => Level::TRACE,
        "debug" => Level::DEBUG,
        "info" => Level::INFO,
        "warn" => Level::WARN,
        "error" => Level::ERROR,
        _ => Level::INFO,
    };

    let subscriber = FmtSubscriber::builder()
        .with_max_level(log_level)
        .with_env_filter(EnvFilter::from_default_env())
        .finish();

    tracing::subscriber::set_global_default(subscriber)
        .expect("Failed to set tracing subscriber");

    info!("🚀 DIDA认证网关启动");
    info!("📋 配置: mode={}, queue_num={}, dns_cache={}",
        args.mode, args.queue_num, args.dns_cache);

    // 打印线程配置信息
    info!("🧵 线程配置: I/O隔离 + 计算隔离");
    info!("   - I/O线程池: 处理nfq、DNS、RPC");
    info!("   - 计算线程池: 处理ECDSA验签");
    info!("   - 阻塞线程池: 处理文件I/O");

    // 加载网关状态
    let state = GatewayState::new(
        &args.config_dir, 
        args.dns_cache, 
        args.max_conns,
        if args.dns_server.is_empty() { None } else { Some(args.dns_server) }
    ).await?;

    info!("✅ 网关状态初始化完成");
    info!("🔐 PK_Top已加载");

    // 根据模式执行不同逻辑
    match args.mode.as_str() {
        "bypass" => {
            info!("🔄 运行模式: bypass（所有流量直通）");
            run_bypass_mode(args.queue_num).await?;
        }
        "query-only" => {
            info!("🔍 运行模式: query-only（DNS+RPC查询，不验证）");
            run_query_only_mode(state, args.queue_num).await?;
        }
        "full" | "exp1" | "exp4" | "exp5a" | "exp5b" => {
            info!("🛡️  运行模式: full（完整双重验证）");
            run_full_mode(state, args.queue_num).await?;
        }
        _ => {
            error!("❌ 未知的运行模式: {}", args.mode);
            return Err(color_eyre::eyre::eyre!("Invalid mode"));
        }
    }

    Ok(())
}

/// Bypass模式：所有流量直通，不进行任何验证
async fn run_bypass_mode(_queue_num: u16) -> Result<()> {
    info!("⚠️  警告：bypass模式不提供任何安全保护！");

    // TODO: 实现nfq直通逻辑
    // 所有报文直接返回NF_ACCEPT

    todo!("实现bypass模式");
}

/// Query-only模式：执行DNS和RPC查询，但不进行验证
async fn run_query_only_mode(_state: std::sync::Arc<GatewayState>, _queue_num: u16) -> Result<()> {
    info!("📊 Query-only模式：将记录查询时延，但不进行验证");

    // TODO: 实现nfq拦截 + DNS/RPC查询逻辑
    // 记录时延但不验证签名

    todo!("实现query-only模式");
}

/// Full模式：完整的双重验证流程
async fn run_full_mode(state: std::sync::Arc<GatewayState>, queue_num: u16) -> Result<()> {
    info!("🛡️  启动完整验证流水线");

    // 使用nfq模块进行报文拦截和验证
    nfq::start_nfq(state, queue_num).await?;

    Ok(())
}
