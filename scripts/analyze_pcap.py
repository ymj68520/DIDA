#!/usr/bin/env python3
"""
Exp-2: DNS报文大小对比分析

对比目标：
1. DIDA方案的TXT记录响应大小
2. DNSSEC签名的TXT记录响应大小
3. 分析UDP截断风险和TCP回退开销

输出：
- CSV数据（含各字段大小）
- 用于论文的统计摘要
"""

import subprocess
import json
import csv
import re
from pathlib import Path
from datetime import datetime

RESULTS_DIR = Path("results/exp2")
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

TEST_DOMAINS = [
    "100.1.168.192.in-addr.arpa",  # 测试域名1
    "101.1.168.192.in-addr.arpa",  # 测试域名2
    "102.1.168.192.in-addr.arpa",  # 测试域名3
]

def dig_query(domain: str, use_dnssec: bool = False) -> dict:
    """
    执行DNS查询并解析响应

    Args:
        domain: 查询域名
        use_dnssec: 是否使用DNSSEC

    Returns:
        dict: 包含响应大小、时间、标志等信息
    """
    cmd = [
        "dig",
        "@127.0.0.2",
        "-p", "53",
        domain,
        "TXT",
        "+short",
        "+nocomments",
        "+noauthority",
        "+noadditional",
    ]

    if use_dnssec:
        cmd.append("+dnssec")

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=5
        )

        # 提取MSG SIZE（需要完整查询）
        full_cmd = cmd.copy()
        full_cmd.remove("+short")
        full_result = subprocess.run(
            full_cmd,
            capture_output=True,
            text=True,
            timeout=5
        )

        # 解析MSG SIZE
        msg_size = 0
        msg_size_match = re.search(r'MSG SIZE\s+edified:\s+(\d+)', full_result.stdout)
        if msg_size_match:
            msg_size = int(msg_size_match.group(1))

        # 解析Query time
        query_time = 0
        time_match = re.search(r'Query time:\s+(\d+)\s+msec', full_result.stdout)
        if time_match:
            query_time = int(time_match.group(1))

        # 解析响应标志
        flags = {}
        if "DO" in full_result.stdout:
            flags['dnssec_ok'] = True
        if "RCODE" in full_result.stdout:
            rcode_match = re.search(r'Status:\s+(\w+)', full_result.stdout)
            if rcode_match:
                flags['rcode'] = rcode_match.group(1)

        # 解析TXT记录内容
        txt_records = []
        for line in result.stdout.strip().split('\n'):
            if line and not line.startswith(';'):
                # 去除引号
                cleaned = line.strip('"')
                txt_records.append(cleaned)

        return {
            'domain': domain,
            'msg_size': msg_size,
            'query_time_ms': query_time,
            'txt_records': txt_records,
            'flags': flags,
            'use_dnssec': use_dnssec,
            'response_size': len(full_result.stdout),
        }

    except subprocess.TimeoutExpired:
        return {
            'domain': domain,
            'error': 'TIMEOUT',
            'use_dnssec': use_dnssec,
        }
    except Exception as e:
        return {
            'domain': domain,
            'error': str(e),
            'use_dnssec': use_dnssec,
        }

def analyze_packet_structure(response: dict) -> dict:
    """
    分析DNS响应包结构

    估算各部分大小：
    - DNS Header: 12 bytes
    - Question Section: ~20 bytes
    - Answer Section: 变长
    - RRSIG/NSEC等DNSSEC记录: 变长
    """
    if 'error' in response:
        return {}

    structure = {
        'header': 12,  # DNS标准头部
        'question': len(response['domain']) + 10,  # 域名长度 + 类型/类
        'answer_base': 0,
        'txt_data': 0,
        'rrsig': 0,
        'dnssec_overhead': 0,
    }

    # 估算TXT记录大小
    for txt in response.get('txt_records', []):
        structure['txt_data'] += len(txt) + 4  # TXT记录头

    # DNSSEC额外开销
    if response['use_dnssec']:
        structure['dnssec_overhead'] = 100  # RRSIG+NSEC估算

    structure['answer_base'] = structure['txt_data'] + 20  # Answer section基础开销
    structure['estimated_total'] = (
        structure['header'] +
        structure['question'] +
        structure['answer_base'] +
        structure['dnssec_overhead']
    )

    return structure

def run_experiment():
    """运行完整实验"""
    print("=" * 60)
    print("Exp-2: DNS报文大小对比分析")
    print("=" * 60)

    results = []

    # 测试每个域名
    for domain in TEST_DOMAINS:
        print(f"\n🔍 测试域名: {domain}")

        # 测试DIDA方案（无DNSSEC）
        print("   [1/2] DIDA方案（无DNSSEC）...")
        dida_response = dig_query(domain, use_dnssec=False)
        dida_structure = analyze_packet_structure(dida_response)

        # 测试DNSSEC方案
        print("   [2/2] DNSSEC方案...")
        dnssec_response = dig_query(domain, use_dnssec=True)
        dnssec_structure = analyze_packet_structure(dnssec_response)

        # 保存结果
        results.append({
            'domain': domain,
            'dida_response': dida_response,
            'dida_structure': dida_structure,
            'dnssec_response': dnssec_response,
            'dnssec_structure': dnssec_structure,
        })

        # 输出即时结果
        if 'error' not in dida_response:
            print(f"      DIDA:   MSG SIZE={dida_response['msg_size']} bytes")
        if 'error' not in dnssec_response:
            print(f"      DNSSEC: MSG SIZE={dnssec_response['msg_size']} bytes")

    # 保存CSV数据
    save_csv_results(results)

    # 生成统计报告
    generate_summary(results)

    print("\n" + "=" * 60)
    print("✅ Exp-2 分析完成")
    print("=" * 60)

def save_csv_results(results: list):
    """保存CSV格式结果"""
    csv_file = RESULTS_DIR / "packet_sizes.csv"

    with open(csv_file, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow([
            'domain',
            'dida_msg_size',
            'dida_query_time_ms',
            'dida_txt_count',
            'dnssec_msg_size',
            'dnssec_query_time_ms',
            'dnssec_txt_count',
            'size_increase',
            'size_increase_pct'
        ])

        for result in results:
            dida = result['dida_response']
            dnssec = result['dnssec_response']

            dida_size = dida.get('msg_size', 0)
            dnssec_size = dnssec.get('msg_size', 0)

            size_increase = dnssec_size - dida_size if dida_size > 0 else 0
            size_increase_pct = (size_increase / dida_size * 100) if dida_size > 0 else 0

            writer.writerow([
                result['domain'],
                dida_size,
                dida.get('query_time_ms', 0),
                len(dida.get('txt_records', [])),
                dnssec_size,
                dnssec.get('query_time_ms', 0),
                len(dnssec.get('txt_records', [])),
                size_increase,
                f"{size_increase_pct:.2f}"
            ])

    print(f"\n💾 CSV数据已保存: {csv_file}")

def generate_summary(results: list):
    """生成统计摘要"""
    summary_file = RESULTS_DIR / "summary.txt"

    # 计算统计数据
    dida_sizes = [r['dida_response'].get('msg_size', 0) for r in results if 'error' not in r['dida_response']]
    dnssec_sizes = [r['dnssec_response'].get('msg_size', 0) for r in results if 'error' not in r['dnssec_response']]

    avg_dida = sum(dida_sizes) / len(dida_sizes) if dida_sizes else 0
    avg_dnssec = sum(dnssec_sizes) / len(dnssec_sizes) if dnssec_sizes else 0

    max_dida = max(dida_sizes) if dida_sizes else 0
    min_dida = min(dida_sizes) if dida_sizes else 0

    max_dnssec = max(dnssec_sizes) if dnssec_sizes else 0
    min_dnssec = min(dnssec_sizes) if dnssec_sizes else 0

    # UDP截断阈值
    UDP_TRUNCATE_THRESHOLD = 512
    UDP_TRUNCATE_LARGE = 4096  # EDNS0

    dida_truncated_512 = sum(1 for s in dida_sizes if s > UDP_TRUNCATE_THRESHOLD)
    dida_truncated_4096 = sum(1 for s in dida_sizes if s > UDP_TRUNCATE_LARGE)

    dnssec_truncated_512 = sum(1 for s in dnssec_sizes if s > UDP_TRUNCATE_THRESHOLD)
    dnssec_truncated_4096 = sum(1 for s in dnssec_sizes if s > UDP_TRUNCATE_LARGE)

    with open(summary_file, 'w') as f:
        f.write("Exp-2: DNS报文大小对比分析\n")
        f.write("=" * 60 + "\n\n")
        f.write(f"测试时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"测试域名数: {len(results)}\n\n")

        f.write("DIDA方案统计:\n")
        f.write(f"  平均大小: {avg_dida:.1f} bytes\n")
        f.write(f"  最小值: {min_dida} bytes\n")
        f.write(f"  最大值: {max_dida} bytes\n")
        f.write(f"  >512字节（需要TCP回退）: {dida_truncated_512}/{len(dida_sizes)}\n")
        f.write(f"  >4096字节（EDNS0截断）: {dida_truncated_4096}/{len(dida_sizes)}\n\n")

        f.write("DNSSEC方案统计:\n")
        f.write(f"  平均大小: {avg_dnssec:.1f} bytes\n")
        f.write(f"  最小值: {min_dnssec} bytes\n")
        f.write(f"  最大值: {max_dnssec} bytes\n")
        f.write(f"  >512字节（需要TCP回退）: {dnssec_truncated_512}/{len(dnssec_sizes)}\n")
        f.write(f"  >4096字节（EDNS0截断）: {dnssec_truncated_4096}/{len(dnssec_sizes)}\n\n")

        f.write("对比分析:\n")
        f.write(f"  大小增加: {avg_dnssec - avg_dida:.1f} bytes\n")
        f.write(f"  增加比例: {((avg_dnssec - avg_dida) / avg_dida * 100) if avg_dida > 0 else 0:.1f}%\n\n")

        f.write("关键发现:\n")
        if dida_truncated_512 == 0:
            f.write("  ✅ DIDA方案所有响应<512字节，无UDP截断\n")
        else:
            f.write(f"  ⚠️  DIDA方案有{dida_truncated_512}个响应需要TCP回退\n")

        if dnssec_truncated_512 > 0:
            f.write(f"  ⚠️  DNSSEC方案有{dnssec_truncated_512}个响应需要TCP回退\n")

        f.write("\n" + "=" * 60 + "\n")

    print(f"📊 统计摘要已保存: {summary_file}")

    # 输出到终端
    print("\n📊 统计摘要:")
    print(f"   DIDA平均:   {avg_dida:.1f} bytes")
    print(f"   DNSSEC平均: {avg_dnssec:.1f} bytes")
    print(f"   增加:       {avg_dnssec - avg_dida:.1f} bytes ({((avg_dnssec - avg_dida) / avg_dida * 100) if avg_dida > 0 else 0:.1f}%)")

if __name__ == "__main__":
    run_experiment()
