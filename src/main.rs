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
use tracing::{info, error, warn, Level};
use tracing_subscriber::{FmtSubscriber, EnvFilter};

mod state;
mod cache;
mod inflight;
mod telemetry;
mod pipeline;
mod nfq;
mod ws_listener;
mod whitelist;
mod xdp;

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

    // 初始化XDP加速层（如果可用）
    if xdp::is_xdp_available() {
        info!("🔧 检测到XDP/eBPF支持，尝试初始化加速层");
        match xdp::init_xdp("eth0").await {
            Ok(_xdp_manager) => {
                info!("✅ XDP加速层初始化成功");
            }
            Err(e) => {
                warn!("⚠️  XDP加速层初始化失败: {}", e);
                info!("   将使用用户态白名单处理");
            }
        }
    } else {
        info!("⚠️  未检测到XDP/eBPF支持，使用用户态白名单处理");
    }

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
async fn run_bypass_mode(queue_num: u16) -> Result<()> {
    info!("⚠️  警告：bypass模式不提供任何安全保护！");

    // 创建并绑定Netfilter queue
    let mut queue = nfq::Queue::open()?;
    queue.bind(queue_num)?;
    
    info!("✅ Bypass模式已启动，队列号: {}", queue_num);
    info!("   所有TCP SYN报文将直接通过，不进行任何验证");
    
    // 主循环
    let mut packet_count = 0;
    loop {
        // 接收报文
        let mut msg = match queue.recv() {
            Ok(m) => m,
            Err(e) => {
                error!("❌ 接收报文失败: {}", e);
                continue;
            }
        };
        
        packet_count += 1;
        
        // 直接返回NF_ACCEPT
        msg.set_verdict(nfq::Verdict::Accept);
        if let Err(e) = queue.verdict(msg) {
            error!("❌ 下发裁决失败: {}", e);
        }
        
        // 定期输出统计
        if packet_count % 100 == 0 {
            info!("📊 统计: 已处理 {} 个报文（全部直通）", packet_count);
        }
    }
}

/// Query-only模式：执行DNS和RPC查询，但不进行验证
async fn run_query_only_mode(state: std::sync::Arc<GatewayState>, queue_num: u16) -> Result<()> {
    info!("📊 Query-only模式：将记录查询时延，但不进行验证");

    // 创建并绑定Netfilter queue
    let mut queue = nfq::Queue::open()?;
    queue.bind(queue_num)?;
    
    info!("✅ Query-only模式已启动，队列号: {}", queue_num);
    info!("   将执行DNS和RPC查询，但不进行签名验证");
    
    // 主循环
    let mut packet_count = 0;
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
        let (src_ip, dst_ip) = match nfq::extract_ips(&msg) {
            Some(ips) => ips,
            None => {
                error!("⚠️  无法提取IP地址，丢弃报文");
                msg.set_verdict(nfq::Verdict::Drop);
                if let Err(e) = queue.verdict(msg) {
                    error!("❌ 下发裁决失败: {}", e);
                }
                continue;
            }
        };
        
        packet_count += 1;
        info!("📦 [{}] {} -> {}", packet_count, src_ip, dst_ip);
        
        // 检查白名单
        if whitelist::is_whitelisted(dst_ip) {
            info!("✅ 白名单地址（绕过验证）: {}", dst_ip);
            msg.set_verdict(nfq::Verdict::Accept);
            if let Err(e) = queue.verdict(msg) {
                error!("❌ 下发裁决失败: {}", e);
            }
            continue;
        }
        
        // 执行DNS查询
        let dns_result = tokio::time::timeout(
            state.dns_timeout,
            pipeline::dns::query_txt(&state, dst_ip),
        ).await;
        
        let (tx_id, _sig_sub) = match dns_result {
            Ok(Ok(v))  => v,
            Ok(Err(e)) => {
                warn!("❌ DNS失败: {}", e);
                msg.set_verdict(nfq::Verdict::Accept);
                if let Err(e) = queue.verdict(msg) {
                    error!("❌ 下发裁决失败: {}", e);
                }
                continue;
            }
            Err(_)     => {
                warn!("❌ DNS timeout");
                msg.set_verdict(nfq::Verdict::Accept);
                if let Err(e) = queue.verdict(msg) {
                    error!("❌ 下发裁决失败: {}", e);
                }
                continue;
            }
        };
        
        info!("✅ DNS查询成功: TxID={:?}", tx_id);
        
        // 执行RPC查询
        let chain_record = match state.cert_cache.get(&tx_id).await {
            Some(record) => {
                info!("✅ 缓存命中");
                record
            }
            None => {
                let rpc_result = tokio::time::timeout(
                    state.rpc_timeout,
                    pipeline::chain::fetch_record(&state, tx_id),
                ).await;
                
                match rpc_result {
                    Ok(Ok(r))  => {
                        let r = std::sync::Arc::new(r);
                        state.cert_cache.insert(tx_id, r.clone()).await;
                        info!("✅ RPC查询成功");
                        r
                    }
                    Ok(Err(e)) => {
                        warn!("❌ RPC失败: {}", e);
                        msg.set_verdict(nfq::Verdict::Accept);
                        if let Err(e) = queue.verdict(msg) {
                            error!("❌ 下发裁决失败: {}", e);
                        }
                        continue;
                    }
                    Err(_)     => {
                        warn!("❌ RPC timeout");
                        msg.set_verdict(nfq::Verdict::Accept);
                        if let Err(e) = queue.verdict(msg) {
                            error!("❌ 下发裁决失败: {}", e);
                        }
                        continue;
                    }
                }
            }
        };
        
        info!("✅ 完成查询: IP={}, 证书前缀={}", 
            dst_ip, chain_record.cert_ip.ip_prefix);
        
        // 直接返回NF_ACCEPT，不进行验证
        msg.set_verdict(nfq::Verdict::Accept);
        if let Err(e) = queue.verdict(msg) {
            error!("❌ 下发裁决失败: {}", e);
        }
        
        // 定期输出统计
        if packet_count % 100 == 0 {
            info!("📊 统计: 已处理 {} 个报文（仅查询）", packet_count);
        }
    }
}

/// Full模式：完整的双重验证流程
async fn run_full_mode(state: std::sync::Arc<GatewayState>, queue_num: u16) -> Result<()> {
    info!("🛡️  启动完整验证流水线");

    // 使用nfq模块进行报文拦截和验证
    nfq::start_nfq(state, queue_num).await?;

    Ok(())
}
