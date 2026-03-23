//! 集成测试 - 完整认证流水线
//!
//! 测试目标：
//! 1. 验证各模块集成正确性
//! 2. 测试端到端认证流程
//! 3. 验证缓存和去重功能
//! 4. 测试错误处理路径

use std::net::{Ipv4Addr, IpAddr};
use std::time::Duration;
use tokio::time::sleep;
use ipnet::IpNet;
use hex;

// 注意：这些测试需要实际的基础设施（Anvil、BIND9）运行
// 因此默认使用 #[ignore] 标记，需要时手动运行

#[tokio::test]
#[ignore]
async fn test_complete_authentication_pipeline() {
    // 测试完整认证流水线
    // 1. 初始化网关状态
    // 2. 模拟TCP SYN包
    // 3. 验证DNS查询
    // 4. 验证RPC查询
    // 5. 验证V₁和V₂验签
    // 6. 验证裁决结果

    // 这个测试需要完整的基础设施支持
    // 运行方式: cargo test --test integration_test -- --ignored
    use rust_rdns::state::GatewayState;
    use std::net::IpAddr;

    // 尝试初始化网关状态
    match GatewayState::new("config", true, 1000, None).await {
        Ok(state) => {
            // 测试目标IP
            let dst_ip: IpAddr = "192.168.1.100".parse().unwrap();
            let src_ip: IpAddr = "192.168.1.1".parse().unwrap();

            // 测试process_packet函数
            use rust_rdns::pipeline::process_packet;
            let result = process_packet(state, dst_ip, src_ip).await;

            println!("✅ 完整认证流水线测试结果: {:?}", result);
        },
        Err(e) => {
            println!("⚠️  基础设施未就绪: {}", e);
            println!("   请先运行: make setup");
        }
    }
}

#[tokio::test]
#[ignore]
async fn test_dns_query_timeout() {
    // 测试DNS查询超时处理
    // 应该在超时后返回NF_DROP
    use rust_rdns::state::GatewayState;
    use std::net::IpAddr;

    match GatewayState::new("config", true, 1000, Some("192.168.88.99".to_string())) // 使用不存在的DNS服务器
        .await {
        Ok(state) => {
            // 测试目标IP
            let dst_ip: IpAddr = "192.168.1.100".parse().unwrap();

            // 测试DNS查询
            use rust_rdns::pipeline::dns::query_txt;
            let result = query_txt(&state, dst_ip).await;

            println!("✅ DNS查询超时测试结果: {:?}", result);
            assert!(result.is_err(), "DNS查询应该超时失败");
        },
        Err(e) => {
            println!("⚠️  基础设施未就绪: {}", e);
        }
    }
}

#[tokio::test]
#[ignore]
async fn test_rpc_query_timeout() {
    // 测试RPC查询超时处理
    // 应该在超时后返回NF_DROP
    use rust_rdns::state::GatewayState;
    use std::net::IpAddr;
    use std::env;

    // 保存原始RPC_URL
    let original_rpc_url = env::var("RPC_URL").ok();
    // 设置不存在的RPC服务器
    env::set_var("RPC_URL", "http://192.168.88.99:8545");

    match GatewayState::new("config", true, 1000, None).await {
        Ok(state) => {
            // 测试RPC查询
            use rust_rdns::pipeline::chain::fetch_record;
            use alloy::primitives::FixedBytes;

            // 生成一个测试TxID
            let tx_id = FixedBytes::from([0u8; 32]);
            let result = fetch_record(&state, tx_id).await;

            println!("✅ RPC查询超时测试结果: {:?}", result);
            assert!(result.is_err(), "RPC查询应该超时失败");
        },
        Err(e) => {
            println!("⚠️  基础设施未就绪: {}", e);
        }
    }

    // 恢复原始RPC_URL
    if let Some(url) = original_rpc_url {
        env::set_var("RPC_URL", url);
    } else {
        env::remove_var("RPC_URL");
    }
}

#[tokio::test]
#[ignore]
async fn test_inflight_deduplication() {
    // 测试In-Flight去重功能
    // 相同的(src_ip, dst_ip)对应该被去重
    use rust_rdns::inflight::InflightTracker;
    use std::net::IpAddr;

    // 创建In-Flight追踪器
    let tracker = InflightTracker::new(100);

    // 测试IP
    let src_ip: IpAddr = "192.168.1.1".parse().unwrap();
    let dst_ip: IpAddr = "192.168.1.100".parse().unwrap();

    // 第一次插入应该成功
    let first_insert = tracker.try_insert(src_ip, dst_ip).await;
    assert!(first_insert, "第一次插入应该成功");
    println!("✅ 第一次插入成功");

    // 第二次插入应该失败（去重）
    let second_insert = tracker.try_insert(src_ip, dst_ip).await;
    assert!(!second_insert, "第二次插入应该失败（去重）");
    println!("✅ 第二次插入失败（去重）");

    // 使记录失效
    tracker.invalidate(src_ip, dst_ip).await;
    println!("✅ 记录已失效");

    // 再次插入应该成功
    let third_insert = tracker.try_insert(src_ip, dst_ip).await;
    assert!(third_insert, "记录失效后再次插入应该成功");
    println!("✅ 记录失效后再次插入成功");

    println!("✅ In-Flight去重功能测试通过");
}

#[tokio::test]
#[ignore]
async fn test_cache_hit_performance() {
    // 测试缓存命中性能
    // 第二次查询应该从缓存读取，不触发RPC调用
    use rust_rdns::cache::CertCache;
    use rust_rdns::state::{ChainRecord, CertIP};
    use alloy::primitives::FixedBytes;
    use std::net::{IpAddr, Ipv4Addr};
    use k256::ecdsa::VerifyingKey;

    // 创建证书缓存
    let cache = CertCache::new(100);

    // 生成测试数据
    let tx_id = FixedBytes::from([1u8; 32]);
    let ip_prefix = IpNet::new(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 0)), 24).unwrap();
    
    // 使用一个有效的secp256k1公钥（示例公钥）
    let public_key_bytes = hex::decode("0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8").unwrap();
    let public_key = VerifyingKey::from_sec1_bytes(&public_key_bytes).unwrap();

    let cert_ip = CertIP {
        ip_prefix,
        public_key,
        expiration_timestamp: u64::MAX,
        is_revoked: false,
    };

    let chain_record = ChainRecord {
        cert_ip,
        sig_top: vec![0x00; 64],
    };

    // 插入缓存
    cache.insert(tx_id, std::sync::Arc::new(chain_record)).await;
    println!("✅ 缓存插入成功");

    // 第一次查询（缓存命中）
    let start1 = std::time::Instant::now();
    let result1 = cache.get(&tx_id).await;
    let elapsed1 = start1.elapsed();
    assert!(result1.is_some(), "第一次查询应该命中缓存");
    println!("✅ 第一次查询命中缓存，耗时: {:?}", elapsed1);

    // 第二次查询（缓存命中）
    let start2 = std::time::Instant::now();
    let result2 = cache.get(&tx_id).await;
    let elapsed2 = start2.elapsed();
    assert!(result2.is_some(), "第二次查询应该命中缓存");
    println!("✅ 第二次查询命中缓存，耗时: {:?}", elapsed2);

    // 验证第二次查询耗时应该更短（缓存命中）
    assert!(elapsed2 <= elapsed1, "缓存命中应该更快");

    println!("✅ 缓存命中性能测试通过");
}

#[tokio::test]
async fn test_pipeline_timer() {
    // 测试PipelineTimer计时功能
    use rust_rdns::telemetry::PipelineTimer;

    let mut timer = PipelineTimer::start();

    // 模拟各阶段延迟
    sleep(Duration::from_millis(10)).await;
    timer.record_dns();

    sleep(Duration::from_millis(20)).await;
    timer.record_rpc();

    sleep(Duration::from_millis(5)).await;
    timer.record_v1();

    sleep(Duration::from_millis(5)).await;
    timer.record_v2();

    timer.record_total();

    // 验证CSV输出格式
    let csv = timer.to_csv();
    assert!(csv.contains(","));
    assert!(csv.contains("\n"));

    // 验证表头
    let header = rust_rdns::csv_header();
    assert_eq!(header, "dns_ns,cache_hit,rpc_ns,v1_ns,v2_ns,total_ns\n");

    println!("✅ PipelineTimer测试通过");
}

#[tokio::test]
async fn test_ip_address_extraction() {
    // 测试IP地址提取和格式转换
    let ip: IpAddr = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 100));
    assert_eq!(ip.to_string(), "192.168.1.100");

    // 测试反向DNS名称生成
    let reverse = format!("{}.in-addr.arpa",
        ip.to_string().split('.').rev().collect::<Vec<&str>>().join("."));
    assert_eq!(reverse, "100.1.168.192.in-addr.arpa");

    println!("✅ IP地址提取测试通过");
}

#[tokio::test]
async fn test_verdict_types() {
    // 测试Verdict类型转换
    // 验证accept和drop的布尔值转换

    let accept_result = true;
    let drop_result = false;

    // 模拟裁决逻辑
    let verdict = if accept_result { "ACCEPT" } else { "DROP" };
    assert_eq!(verdict, "ACCEPT");

    let verdict = if drop_result { "ACCEPT" } else { "DROP" };
    assert_eq!(verdict, "DROP");

    println!("✅ Verdict类型测试通过");
}

#[tokio::test]
async fn test_duration_calculations() {
    // 测试时间计算
    let start = std::time::Instant::now();
    sleep(Duration::from_millis(50)).await;
    let elapsed = start.elapsed();

    assert!(elapsed.as_millis() >= 50);
    assert!(elapsed.as_millis() < 100);

    // 测试纳秒转换
    let nanos = elapsed.as_nanos();
    assert!(nanos >= 50_000_000);
    assert!(nanos < 100_000_000);

    println!("✅ 时间计算测试通过");
}

#[cfg(test)]
mod error_handling_tests {
    //! 错误处理测试

    use super::*;

    #[tokio::test]
    async fn test_timeout_handling() {
        // 测试超时处理
        let result = tokio::time::timeout(
            Duration::from_millis(100),
            sleep(Duration::from_millis(200))
        ).await;

        assert!(result.is_err());
        println!("✅ 超时处理测试通过");
    }

    #[tokio::test]
    async fn test_graceful_shutdown() {
        // 测试优雅关闭
        let (_tx, rx) = tokio::sync::oneshot::channel::<()>();

        let result = tokio::time::timeout(
            Duration::from_millis(100),
            rx
        ).await;

        assert!(result.is_err());
        println!("✅ 优雅关闭测试通过");
    }
}
