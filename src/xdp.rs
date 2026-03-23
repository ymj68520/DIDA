//! XDP/eBPF加速层
//! 
//! 功能：
//! - 在内核驱动层对已建立信任的IP集合执行快速MAP查找
//! - 直接放行白名单流量，绕过用户态处理
//! - 仅支持IP白名单初筛，不执行密码学验证

use std::net::IpAddr;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::{info, debug};

// 条件编译：仅当启用XDP支持时才编译相关代码
#[cfg(feature = "xdp")]
use aya::maps::{HashMap};
#[cfg(feature = "xdp")]
use aya::programs::{Xdp, XdpFlags};
#[cfg(feature = "xdp")]
use aya::{include_bytes_aligned, Bpf};

/// XDP/eBPF程序管理
#[cfg(feature = "xdp")]
pub struct XdpManager {
    bpf: Bpf,
    iface: String,
    whitelist_map: Option<HashMap<Arc<Bpf>, u32, [u8; 4]>>,
}

#[cfg(feature = "xdp")]
impl XdpManager {
    /// 创建新的XDP管理器
    /// 
    /// # Arguments
    /// * `iface` - 网络接口名称
    pub fn new(iface: &str) -> Result<Self, Box<dyn std::error::Error>> {
        // 加载eBPF程序
        let bpf = Bpf::load(include_bytes_aligned!("../bpf/xdp_whitelist.o"))?;
        
        // 获取白名单映射
        let whitelist_map = HashMap::try_from(bpf.map("WHITELIST_MAP")?)?;
        
        info!("✅ XDP/eBPF程序加载成功");
        info!("   网络接口: {}", iface);
        
        Ok(Self {
            bpf,
            iface: iface.to_string(),
            whitelist_map: Some(whitelist_map),
        })
    }
    
    /// 启动XDP程序
    pub fn start(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        // 获取XDP程序
        let program: &mut Xdp = self.bpf.program("xdp_whitelist")?.try_into()?;
        
        // 附加到网络接口
        program.load()?;
        program.attach(&self.iface, XdpFlags::default())?;
        
        info!("✅ XDP程序已附加到接口: {}", self.iface);
        Ok(())
    }
    
    /// 停止XDP程序
    pub fn stop(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        // 获取XDP程序并 detach
        let program: &mut Xdp = self.bpf.program("xdp_whitelist")?.try_into()?;
        program.detach(&self.iface)?;
        
        info!("✅ XDP程序已从接口分离: {}", self.iface);
        Ok(())
    }
    
    /// 添加IP到白名单
    pub fn add_to_whitelist(&mut self, ip: IpAddr) -> Result<(), Box<dyn std::error::Error>> {
        if let Some(map) = &mut self.whitelist_map {
            // 将IP转换为网络字节序的32位整数
            let key = match ip {
                IpAddr::V4(ipv4) => {
                    let octets = ipv4.octets();
                    u32::from_be_bytes([octets[0], octets[1], octets[2], octets[3]])
                }
                IpAddr::V6(_) => {
                    // 暂时只支持IPv4
                    return Err("IPv6 not supported in XDP whitelist".into());
                }
            };
            
            // 值为1表示在白名单中
            map.insert(key, &[1; 4], 0)?;
            debug!("✅ XDP白名单添加IP: {}", ip);
        }
        Ok(())
    }
    
    /// 从白名单移除IP
    pub fn remove_from_whitelist(&mut self, ip: IpAddr) -> Result<(), Box<dyn std::error::Error>> {
        if let Some(map) = &mut self.whitelist_map {
            // 将IP转换为网络字节序的32位整数
            let key = match ip {
                IpAddr::V4(ipv4) => {
                    let octets = ipv4.octets();
                    u32::from_be_bytes([octets[0], octets[1], octets[2], octets[3]])
                }
                IpAddr::V6(_) => {
                    // 暂时只支持IPv4
                    return Err("IPv6 not supported in XDP whitelist".into());
                }
            };
            
            map.remove(&key, 0)?;
            debug!("✅ XDP白名单移除IP: {}", ip);
        }
        Ok(())
    }
    
    /// 批量添加白名单IP
    pub fn add_whitelist_batch(&mut self, ips: &[IpAddr]) -> Result<(), Box<dyn std::error::Error>> {
        for ip in ips {
            self.add_to_whitelist(*ip)?;
        }
        info!("✅ XDP白名单批量添加完成: {} IPs", ips.len());
        Ok(())
    }
}

/// 非XDP模式的空实现
#[cfg(not(feature = "xdp"))]
pub struct XdpManager {
    iface: String,
}

#[cfg(not(feature = "xdp"))]
impl XdpManager {
    pub fn new(iface: &str) -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self {
            iface: iface.to_string(),
        })
    }
    
    pub fn start(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        info!("⚠️  XDP功能未启用，使用用户态白名单");
        Ok(())
    }
    
    pub fn stop(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        Ok(())
    }
    
    pub fn add_to_whitelist(&mut self, _ip: IpAddr) -> Result<(), Box<dyn std::error::Error>> {
        Ok(())
    }
    
    pub fn remove_from_whitelist(&mut self, _ip: IpAddr) -> Result<(), Box<dyn std::error::Error>> {
        Ok(())
    }
    
    pub fn add_whitelist_batch(&mut self, _ips: &[IpAddr]) -> Result<(), Box<dyn std::error::Error>> {
        Ok(())
    }
}

/// 初始化XDP加速层
pub async fn init_xdp(iface: &str) -> Result<Arc<Mutex<XdpManager>>, Box<dyn std::error::Error>> {
    let mut manager = XdpManager::new(iface)?;
    manager.start()?;
    
    // 加载现有的白名单
    let whitelist = crate::whitelist::get_whitelist_config();
    
    // 添加IP白名单
    for ip in &whitelist.ips {
        if let Ok(_) = manager.add_to_whitelist(*ip) {
            debug!("✅ 从配置加载XDP白名单IP: {}", ip);
        }
    }
    
    // 注意：CIDR网段需要转换为单个IP才能添加到XDP映射
    // 这里简化处理，只添加精确IP
    
    #[cfg(feature = "xdp")]
    info!("✅ XDP/eBPF加速层初始化完成");
    #[cfg(not(feature = "xdp"))]
    info!("⚠️  XDP功能未启用，使用用户态白名单");
    info!("   已加载 {} 个白名单IP", whitelist.ips.len());
    
    Ok(Arc::new(Mutex::new(manager)))
}

/// 检查XDP是否可用
pub fn is_xdp_available() -> bool {
    // 检查是否存在bpf目录
    Path::new("/sys/fs/bpf").exists()
}
