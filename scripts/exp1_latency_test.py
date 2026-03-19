#!/usr/bin/env python3
"""
Exp-1: 端到端时延测试

测试目标：
1. 测量完整认证流水线的端到端时延
2. 分解各阶段时延（DNS查询、RPC查询、V₁验签、V₂验签）
3. 生成CSV数据用于IEEE论文图表

测试方法：
- 发送TCP SYN包到测试IP地址
- 通过nfq拦截并记录各阶段时延
- 重复100次并统计数据
"""

import subprocess
import time
import csv
import json
import socket
import struct
import statistics
from pathlib import Path
from datetime import datetime

# 配置
TEST_COUNT = 100
TEST_IPS = [
    "192.168.1.100",  # 测试IP1
    "192.168.1.101",  # 测试IP2
    "192.168.1.102",  # 测试IP3
]
RESULTS_DIR = Path("results/exp1")
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

def load_cert_manifest():
    """加载凭证清单"""
    with open("config/cert_manifest.json", "r") as f:
        return json.load(f)

def create_raw_tcp_socket(target_ip):
    """创建原始TCP套接字用于发送SYN包"""
    try:
        # 创建原始套接字
        sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_TCP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        return sock
    except PermissionError:
        print("❌ 需要root权限发送原始TCP包")
        print("   请使用: sudo python3 scripts/exp1_latency_test.py")
        return None

def build_syn_packet(src_ip, dst_ip, src_port, dst_port):
    """构建TCP SYN报文"""
    # IP头部
    ip_ihl = 5
    ip_ver = 4
    ip_tos = 0
    ip_tot_len = 20 + 20  # IP header + TCP header
    ip_id = 54321
    ip_frag_off = 0
    ip_ttl = 64
    ip_proto = socket.IPPROTO_TCP
    ip_check = 0  # 内核会填充

    ip_header = struct.pack(
        "!BBHHHBBH4s4s",
        (ip_ver << 4) + ip_ihl,
        ip_tos,
        ip_tot_len,
        ip_id,
        ip_frag_off,
        ip_ttl,
        ip_proto,
        ip_check,
        socket.inet_aton(src_ip),
        socket.inet_aton(dst_ip)
    )

    # TCP头部
    tcp_seq = 0
    tcp_ack_seq = 0
    tcp_doff = 5
    tcp_fin = 0
    tcp_syn = 1
    tcp_rst = 0
    tcp_psh = 0
    tcp_ack = 0
    tcp_urg = 0
    tcp_window = socket.htons(5840)
    tcp_check = 0
    tcp_urg_ptr = 0

    tcp_header = struct.pack(
        "!HHLLBBHHH",
        src_port,
        dst_port,
        tcp_seq,
        tcp_ack_seq,
        (tcp_doff << 4) | tcp_fin | tcp_syn | tcp_rst | tcp_psh | tcp_ack | tcp_urg,
        tcp_window,
        tcp_check,
        tcp_urg_ptr
    )

    return ip_header + tcp_header

def send_syn_packets(target_ip, count=10):
    """发送TCP SYN包"""
    sock = create_raw_tcp_socket(target_ip)
    if not sock:
        return []

    src_ip = "192.168.1.1"  # 模拟源IP
    src_port = 12345

    sent_times = []

    for i in range(count):
        try:
            # 构建SYN包
            packet = build_syn_packet(
                src_ip,
                target_ip,
                src_port + i,
                80  # 目标端口
            )

            # 发送
            send_time = time.time()
            sock.sendto(packet, (target_ip, 0))
            sent_times.append(send_time)

            # 小延迟避免包风暴
            time.sleep(0.01)

        except Exception as e:
            print(f"❌ 发送SYN包失败: {e}")

    sock.close()
    return sent_times

def start_gateway():
    """启动认证网关"""
    print("🚀 启动认证网关...")

    # 检查是否需要sudo
    try:
        subprocess.run(
            ["cargo", "run", "--release", "--bin", "auth-gateway", "--",
             "--mode", "full", "--queue-num", "0"],
            check=True,
            timeout=300,
            capture_output=True
        )
        return True
    except PermissionError:
        print("❌ 需要root权限运行网关（需要访问nfqueue）")
        print("   请使用: sudo cargo run --release --bin auth-gateway -- --mode full --queue-num 0")
        return False
    except subprocess.TimeoutExpired:
        print("⏰ 网关运行超时（5分钟）")
        return True
    except Exception as e:
        print(f"❌ 启动网关失败: {e}")
        return False

def run_experiment(target_ip, test_count=100):
    """运行单次实验"""
    print(f"\n🎯 测试目标: {target_ip}")
    print(f"   发送 {test_count} 个TCP SYN包")

    # 发送SYN包
    send_syn_packets(target_ip, test_count)

    # 等待网关处理
    time.sleep(2)

    print(f"✅ {target_ip} 测试完成")

def analyze_results():
    """分析实验结果"""
    print("\n📊 分析实验结果...")

    # 读取网关输出的时延数据
    # 注意：这需要网关输出CSV格式的时延数据
    csv_file = RESULTS_DIR / "latency_data.csv"

    if not csv_file.exists():
        print("⚠️  未找到时延数据文件")
        print(f"   期望路径: {csv_file}")
        return

    # 读取CSV数据
    with open(csv_file, "r") as f:
        reader = csv.DictReader(f)
        data = list(reader)

    if not data:
        print("⚠️  时延数据为空")
        return

    # 统计各阶段时延
    dns_latencies = [int(row["dns_ns"]) for row in data if row["dns_ns"] != "0"]
    rpc_latencies = [int(row["rpc_ns"]) for row in data if row["rpc_ns"] != "0"]
    v1_latencies = [int(row["v1_ns"]) for row in data if row["v1_ns"] != "0"]
    v2_latencies = [int(row["v2_ns"]) for row in data if row["v2_ns"] != "0"]
    total_latencies = [int(row["total_ns"]) for row in data]

    # 计算统计数据
    def compute_stats(latencies, name):
        if not latencies:
            print(f"\n{name}: 无数据")
            return

        mean = statistics.mean(latencies)
        median = statistics.median(latencies)
        stdev = statistics.stdev(latencies) if len(latencies) > 1 else 0
        p95 = statistics.quantiles(latencies, n=20)[18] if len(latencies) > 1 else latencies[0]
        p99 = statistics.quantiles(latencies, n=100)[98] if len(latencies) > 1 else latencies[0]

        print(f"\n{name}:")
        print(f"   样本数: {len(latencies)}")
        print(f"   平均值: {mean/1000:.2f} μs")
        print(f"   中位数: {median/1000:.2f} μs")
        print(f"   标准差: {stdev/1000:.2f} μs")
        print(f"   P95: {p95/1000:.2f} μs")
        print(f"   P99: {p99/1000:.2f} μs")

    compute_stats(dns_latencies, "DNS查询时延")
    compute_stats(rpc_latencies, "RPC查询时延")
    compute_stats(v1_latencies, "V₁验签时延")
    compute_stats(v2_latencies, "V₂验签时延")
    compute_stats(total_latencies, "端到端总时延")

    # 保存汇总统计
    summary_file = RESULTS_DIR / "summary.txt"
    with open(summary_file, "w") as f:
        f.write(f"Exp-1 端到端时延测试汇总\n")
        f.write(f"测试时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"测试IPs: {', '.join(TEST_IPS)}\n")
        f.write(f"总样本数: {len(data)}\n\n")

        if dns_latencies:
            f.write(f"DNS查询平均时延: {statistics.mean(dns_latencies)/1000:.2f} μs\n")
        if rpc_latencies:
            f.write(f"RPC查询平均时延: {statistics.mean(rpc_latencies)/1000:.2f} μs\n")
        if v1_latencies:
            f.write(f"V₁验签平均时延: {statistics.mean(v1_latencies)/1000:.2f} μs\n")
        if v2_latencies:
            f.write(f"V₂验签平均时延: {statistics.mean(v2_latencies)/1000:.2f} μs\n")
        if total_latencies:
            f.write(f"端到端平均时延: {statistics.mean(total_latencies)/1000:.2f} μs\n")

    print(f"\n✅ 汇总报告已保存: {summary_file}")

def main():
    """主函数"""
    print("=" * 60)
    print("Exp-1: 端到端时延测试")
    print("=" * 60)

    # 加载配置
    cert_manifest = load_cert_manifest()
    print(f"✅ 加载了 {len(cert_manifest['certificates'])} 个凭证")

    # 运行实验
    for test_ip in TEST_IPS:
        run_experiment(test_ip, TEST_COUNT)

    # 分析结果
    analyze_results()

    print("\n" + "=" * 60)
    print("✅ Exp-1 测试完成")
    print("=" * 60)

if __name__ == "__main__":
    main()
