#!/usr/bin/env python3
"""
BIND9 Zone文件生成脚本 - DIDA系统

功能：
根据cert_manifest.json生成BIND9 zone文件，为每个IP配置TXT记录。
TXT记录格式：
    <ip_reversed>.in-addr.arpa. IN TXT "v1|<tx_id>|<sig_sub>"

依赖：
    无（仅使用Python标准库）

配置文件：
    config/cert_manifest.json - 证书清单

输出文件：
    config/rdns.zone - BIND9 zone文件
    config/named.conf.local - BIND9配置片段

使用方法：
    python3 scripts/gen_zone.py

部署：
    1. 复制 config/named.conf.local 到 /etc/bind/named.conf.local
    2. 复制 config/rdns.zone 到 /etc/bind/zones/rdns.zone
    3. 重启BIND9: sudo systemctl restart bind9

验证：
    dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT
"""

import os
import sys
import json
import argparse
from pathlib import Path
from datetime import datetime

# 添加项目根目录到路径
PROJECT_ROOT = Path(__file__).parent.parent
CONFIG_DIR = PROJECT_ROOT / "config"

# Zone配置
ZONE_NAME = "1.168.192.in-addr.arpa"  # 示例：192.168.1.0/24网段
ZONE_FILE = CONFIG_DIR / "rdns.zone"
NAMED_CONF_LOCAL = CONFIG_DIR / "named.conf.local"

def reverse_ip(ip_str):
    """
    将IP地址转换为反向DNS格式

    Args:
        ip_str: IP地址（如192.168.1.100）

    Returns:
        反向DNS格式（如100.1.168.192.in-addr.arpa）
    """
    # 提取IP地址（处理CIDR格式）
    if '/' in ip_str:
        ip_str = ip_str.split('/')[0]

    parts = ip_str.split('.')
    if len(parts) != 4:
        raise ValueError(f"无效的IP地址: {ip_str}")

    # 反转IP地址
    reversed_ip = '.'.join(reversed(parts))
    return f"{reversed_ip}.in-addr.arpa"

def parse_ip_prefix(ip_prefix):
    """
    解析IP前缀，提取网络地址和掩码

    Args:
        ip_prefix: CIDR格式（如192.168.1.0/24）

    Returns:
        tuple: (network_addr, prefix_len)
    """
    if '/' not in ip_prefix:
        raise ValueError(f"无效的CIDR格式: {ip_prefix}")

    network, prefix_len = ip_prefix.split('/')
    prefix_len = int(prefix_len)

    return network, prefix_len

def generate_zone_record(cert_record):
    """
    为单个证书生成DNS TXT记录

    Args:
        cert_record: 证书记录字典

    Returns:
        tuple: (dns_name, txt_record)
    """
    ip_prefix = cert_record['ip_prefix']
    tx_id = cert_record['tx_id']
    sig_sub = cert_record['sig_sub']

    # 解析IP前缀
    network, prefix_len = parse_ip_prefix(ip_prefix)

    # 对于单个IP，生成完整记录
    # 对于子网，这里简化处理，只生成网络地址的记录
    # 实际部署时可能需要为每个IP生成单独的记录
    if prefix_len == 32:
        # 单个IP
        ip_addr = network
        dns_name = reverse_ip(ip_addr)
    else:
        # 子网（使用网络地址作为示例）
        ip_addr = network
        dns_name = reverse_ip(ip_addr)

    # TXT记录格式: "v1|<tx_id>|<sig_sub>"
    # 协议版本号（v1）+ TxID + Sig_Sub
    txt_value = f"v1|{tx_id}|{sig_sub}"

    return dns_name, txt_value

def generate_zone_file(cert_manifest):
    """
    生成完整的BIND9 zone文件

    Args:
        cert_manifest: 证书清单字典

    Returns:
        str: zone文件内容
    """
    # Zone文件头部
    zone_content = f"""
; BIND9 Zone File for DIDA rDNS
; Generated at: {datetime.now().isoformat()}
; Total certificates: {cert_manifest['total_certs']}

$ORIGIN {ZONE_NAME}.
$TTL 300  ; 5分钟缓存时间

@   IN  SOA localhost. root.localhost. (
        {datetime.now().strftime('%Y%m%d%H')}  ; Serial (YYYYMMDDHH)
        3600        ; Refresh (1 hour)
        1800        ; Retry (30 minutes)
        604800      ; Expire (1 week)
        86400 )     ; Minimum TTL (1 day)

    IN  NS  localhost.

; TXT记录格式：v1|<tx_id>|<sig_sub>
; v1: 协议版本号
; tx_id: 链上凭证索引（32字节）
; sig_sub: 节点对(IP||TxID)的签名（V2验签使用）

"""

    # 为每个证书生成TXT记录
    for cert in cert_manifest['certificates']:
        dns_name, txt_value = generate_zone_record(cert)

        # 提取最后一段IP地址（相对于zone origin）
        # 例如：100.1.168.192.in-addr.arpa -> 100
        rel_name = dns_name.split('.')[0]

        zone_content += f"{rel_name} IN TXT \"{txt_value}\"\n"
        zone_content += f"; IP: {cert['ip_prefix']}, TxID: {cert['tx_id'][:16]}...\n"

    return zone_content

def generate_named_conf_local():
    """
    生成named.conf.local配置片段

    Returns:
        str: 配置文件内容
    """
    conf_content = f"""
// DIDA rDNS Zone Configuration
// Generated at: {datetime.now().isoformat()}

zone "{ZONE_NAME}" {{
    type master;
    file "{ZONE_FILE}";
}};

// 监听配置（添加到/etc/bind/named.conf.options）:
// options {{
//     listen-on port 53 {{ 127.0.0.2; }};
//     allow-query {{ any; }};
// }};
"""
    return conf_content

def load_cert_manifest():
    """加载证书清单"""
    manifest_path = CONFIG_DIR / "cert_manifest.json"

    if not manifest_path.exists():
        raise FileNotFoundError(f"证书清单不存在: {manifest_path}")

    with open(manifest_path) as f:
        manifest = json.load(f)

    if manifest['total_certs'] == 0:
        raise ValueError("证书清单为空，请先运行 scripts/provision_certs.py")

    return manifest

def save_zone_file(zone_content):
    """保存zone文件"""
    with open(ZONE_FILE, 'w') as f:
        f.write(zone_content)

    print(f"✅ Zone文件已生成: {ZONE_FILE}")

def save_named_conf_local(conf_content):
    """保存named.conf.local"""
    with open(NAMED_CONF_LOCAL, 'w') as f:
        f.write(conf_content)

    print(f"✅ BIND9配置已生成: {NAMED_CONF_LOCAL}")

def print_deployment_instructions():
    """打印部署指令"""
    print("\n" + "="*70)
    print("📋 BIND9部署指令：")
    print("="*70)
    print(f"\n1. 复制zone文件到BIND9目录：")
    print(f"   sudo mkdir -p /etc/bind/zones")
    print(f"   sudo cp {ZONE_FILE} /etc/bind/zones/")
    print(f"   sudo chown bind:bind /etc/bind/zones/rdns.zone")

    print(f"\n2. 配置named.conf.local：")
    print(f"   sudo cp {NAMED_CONF_LOCAL} /etc/bind/named.conf.local")

    print(f"\n3. 配置监听地址（编辑/etc/bind/named.conf.options）：")
    print(f"   添加以下配置到options块：")
    print(f"   listen-on port 53 {{ 127.0.0.2; }};")
    print(f"   allow-query {{ any; }};")

    print(f"\n4. 检查配置语法：")
    print(f"   sudo named-checkconf")
    print(f"   sudo named-checkzone {ZONE_NAME} /etc/bind/zones/rdns.zone")

    print(f"\n5. 重启BIND9：")
    print(f"   sudo systemctl restart bind9")
    print(f"   或：sudo systemctl restart named")

    print(f"\n6. 验证DNS解析：")
    print(f"   dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT")

    print("\n" + "="*70)

def main():
    parser = argparse.ArgumentParser(description='BIND9 Zone文件生成脚本')
    parser.add_argument('--verify', action='store_true', help='仅验证证书清单，不生成文件')
    args = parser.parse_args()

    try:
        print("🔧 DIDA BIND9 Zone文件生成器")
        print("="*70)

        # 加载证书清单
        print("\n📋 加载证书清单...")
        manifest = load_cert_manifest()
        print(f"✅ 已加载 {manifest['total_certs']} 个证书")

        # 验证模式
        if args.verify:
            print("\n✅ 证书清单验证通过")
            for cert in manifest['certificates']:
                print(f"  - {cert['ip_prefix']}: {cert['tx_id'][:16]}...")
            return 0

        # 生成zone文件
        print("\n📝 生成Zone文件...")
        zone_content = generate_zone_file(manifest)
        save_zone_file(zone_content)

        # 生成配置文件
        print("\n📝 生成BIND9配置...")
        conf_content = generate_named_conf_local()
        save_named_conf_local(conf_content)

        # 打印部署指令
        print_deployment_instructions()

        print("\n✅ Zone文件生成完成！")
        return 0

    except Exception as e:
        print(f"\n❌ 错误: {e}")
        import traceback
        traceback.print_exc()
        return 1

if __name__ == "__main__":
    sys.exit(main())
