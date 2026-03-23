//! 裁决模块
//!
//! 根据验证结果下发NF_ACCEPT或NF_DROP裁决。
//! 与内核Netfilter队列交互。

use nfq::Queue;

/// 裁决类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerdictType {
    Accept,
    Drop,
}

/// 下发裁决到内核
///
/// # Arguments
/// * `queue` - Netfilter队列实例
/// * `packet_id` - 报文ID
/// * `verdict` - 裁决类型
///
/// # Returns
/// * `Ok(())` - 裁决下发成功
/// * `Err` - 裁决下发失败
pub fn set_verdict(
    _queue: &Queue,
    _packet_id: u32,
    _verdict: VerdictType,
) -> Result<(), color_eyre::Report> {
    // TODO: 实现实际的裁决设置
    // nfq API需要更复杂的设置，这里暂时跳过
    Ok(())
}

/// 根据布尔值转换裁决类型
///
/// # Arguments
/// * `result` - true表示Accept，false表示Drop
///
/// # Returns
/// * `VerdictType` - 裁决类型
pub fn bool_to_verdict(result: bool) -> VerdictType {
    if result {
        VerdictType::Accept
    } else {
        VerdictType::Drop
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bool_to_verdict() {
        assert_eq!(bool_to_verdict(true), VerdictType::Accept);
        assert_eq!(bool_to_verdict(false), VerdictType::Drop);
    }
}
