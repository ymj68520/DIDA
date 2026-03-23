//! 认证流水线模块
//!
//! 实现完整的双重身份验证流程：
//! 1. DNS查询获取TxID + Sig_Sub
//! 2. RPC查询获取Cert_IP + Sig_Top
//! 3. V₁验证（PK_Top验Sig_Top）
//! 4. V₂验证（PK_Sub验Sig_Sub）
//! 5. 裁决（NF_ACCEPT/NF_DROP）

pub mod dns;
pub mod chain;
pub mod crypto;
pub mod verdict;

use std::sync::Arc;
use std::net::IpAddr;
use crate::state::GatewayState;
use crate::telemetry::PipelineTimer;

/// 处理单个TCP SYN报文的完整流水线
///
/// # Arguments
/// * `state` - 网关状态
/// * `dst_ip` - 目标IP地址
/// * `src_ip` - 源IP地址
///
/// # Returns
/// * `true` - NF_ACCEPT
/// * `false` - NF_DROP
pub async fn process_packet(
    state: Arc<GatewayState>,
    dst_ip: IpAddr,
    src_ip: IpAddr,
) -> bool {

    // ── In-Flight 去重（防 TCP 重传） ──────────────────────────
    if !state.inflight.try_insert(src_ip, dst_ip).await {
        tracing::debug!("In-flight duplicate, skipping: {} -> {}", src_ip, dst_ip);
        return false;
    }

    let mut timer = PipelineTimer::start();
    let result = process_inner(&state, dst_ip, &mut timer).await;

    state.inflight.invalidate(src_ip, dst_ip).await;
    timer.record_total();
    result
}

/// 内部处理逻辑（不包含In-Flight追踪）
async fn process_inner(
    state: &GatewayState,
    dst_ip: IpAddr,
    timer: &mut PipelineTimer,
) -> bool {
    // ── Step 1: 带外 DNS 查询（获取 TxID + Sig_Sub） ────────────
    let dns_result = tokio::time::timeout(
        state.dns_timeout,
        dns::query_txt(state, dst_ip),
    ).await;

    let (tx_id, sig_sub) = match dns_result {
        Ok(Ok(v))  => v,
        Ok(Err(e)) => {
            tracing::warn!("❌ DNS failed: {}", e);
            return false;
        }
        Err(_)     => {
            tracing::warn!("❌ DNS timeout");
            return false;
        }
    };

    tracing::debug!("✅ DNS查询成功: TxID={:?}", tx_id);
    timer.record_dns();

    // ── Step 2: 链上状态查询（Cache 优先，Miss 则 RPC） ─────────
    let chain_record: Arc<crate::state::ChainRecord> = match state.cert_cache.get(&tx_id).await {
        Some(record) => {
            tracing::debug!("✅ 缓存命中");
            timer.record_cache_hit();
            record
        }
        None => {
            let rpc_result = tokio::time::timeout(
                state.rpc_timeout,
                chain::fetch_record(state, tx_id),
            ).await;

            match rpc_result {
                Ok(Ok(r))  => {
                    let r = Arc::new(r);
                    state.cert_cache.insert(tx_id, r.clone()).await;
                    tracing::debug!("✅ RPC查询成功");
                    timer.record_rpc();
                    r
                }
                Ok(Err(e)) => {
                    tracing::warn!("❌ RPC failed: {}", e);
                    return false;
                }
                Err(_)     => {
                    tracing::warn!("❌ RPC timeout");
                    return false;
                }
            }
        }
    };

    // ── Step 3: V₁ 校验（用本地 PK_Top 验 Sig_Top） ─────────────
    let record_clone = chain_record.clone();
    let pk_top_clone = state.pk_top;
    let dst_ip_clone = dst_ip;

    let v1_ok = tokio::task::spawn_blocking(move || {
        crypto::verify_v1(&pk_top_clone, &record_clone, dst_ip_clone)
    }).await.unwrap_or(false);

    timer.record_v1();

    if !v1_ok {
        tracing::warn!("❌ V₁验证失败: {}", dst_ip);
        return false;
    }

    tracing::debug!("✅ V₁验证通过");

    // ── Step 4: V₂ 校验（从 Cert_IP 提取 PK_Sub 验 Sig_Sub） ────
    let pk_sub = chain_record.cert_ip.public_key;

    let v2_ok = tokio::task::spawn_blocking(move || {
        crypto::verify_v2(&pk_sub, &sig_sub, dst_ip_clone, tx_id)
    }).await.unwrap_or(false);

    timer.record_v2();

    if !v2_ok {
        tracing::warn!("❌ V₂验证失败: {}", dst_ip);
        return false;
    }

    tracing::info!("✅ 认证成功: {}", dst_ip);
    true
}
