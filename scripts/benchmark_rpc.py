#!/usr/bin/env python3
"""
Exp-3: RPC查询时延 vs 数据规模基准测试

测试目标：
- 100条记录：平均时延 < 50ms
- 1,000条记录：平均时延 < 100ms
- 10,000条记录：平均时延 < 200ms

输出格式：
results/exp3/rpc_latency.csv
    record_count,latency_ms,timestamp
"""

import sys
import json
import time
import csv
import statistics
from pathlib import Path
from datetime import datetime
from typing import List, Dict

# 项目路径
PROJECT_ROOT = Path(__file__).parent.parent
CONFIG_DIR = PROJECT_ROOT / "config"
RESULTS_DIR = PROJECT_ROOT / "results" / "exp3"


def load_contract_config():
    """加载合约配置"""
    with open(CONFIG_DIR / "contract.env") as f:
        config = {}
        for line in f:
            if '=' in line and not line.strip().startswith('#'):
                key, value = line.strip().split('=', 1)
                config[key] = value.strip()
        return config


def load_cert_manifest():
    """加载证书清单"""
    with open(CONFIG_DIR / "cert_manifest.json") as f:
        return json.load(f)


def query_record_via_cast(contract_addr, tx_id):
    """
    通过cast命令查询单个记录

    Args:
        contract_addr: 合约地址
        tx_id: 交易ID

    Returns:
        查询时延（毫秒）
    """
    import subprocess

    start = time.perf_counter()

    cmd = [
        "cast", "call", contract_addr,
        "isValid(bytes32,bool)",
        tx_id,
        "--rpc-url", "http://127.0.0.1:8545"
    ]

    try:
        subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        latency_ms = (time.perf_counter() - start) * 1000
        return latency_ms
    except subprocess.TimeoutExpired:
        return None
    except Exception as e:
        print(f"查询失败: {e}")
        return None


def run_benchmark(scales: List[int]):
    """
    运行RPC时延基准测试

    Args:
        scales: 测试规模列表，如 [100, 1000, 10000]
    """
    # 创建结果目录
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    # 加载配置
    config = load_contract_config()
    contract_addr = config['CONTRACT_ADDR']

    # 加载证书清单
    manifest = load_cert_manifest()
    all_certs = manifest['certificates']

    # 准备输出CSV
    output_file = RESULTS_DIR / "rpc_latency.csv"
    with open(output_file, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['record_count', 'latency_ms', 'timestamp', 'tx_id'])

        # 对每个规模进行测试
        for scale in scales:
            print(f"\n{'='*70}")
            print(f"📊 测试规模: {scale:,} 条记录")
            print(f"{'='*70}")

            if scale > len(all_certs):
                print(f"⚠️  警告：证书总数不足 {scale:,}，仅测试 {len(all_certs):,} 条")
                scale = len(all_certs)

            # 随机选择要查询的TxID
            import random
            test_tx_ids = random.sample([c['tx_id'] for c in all_certs[:scale]], min(100, scale))

            latencies = []

            # 执行查询
            for i, tx_id in enumerate(test_tx_ids):
                if (i + 1) % 10 == 0:
                    print(f"  进度: {i+1}/{len(test_tx_ids)}")

                latency = query_record_via_cast(contract_addr, tx_id)

                if latency is not None:
                    latencies.append(latency)
                    writer.writerow([
                        scale,
                        f"{latency:.2f}",
                        datetime.now().isoformat(),
                        tx_id
                    ])

            # 统计结果
            if latencies:
                avg_latency = statistics.mean(latencies)
                min_latency = min(latencies)
                max_latency = max(latencies)
                median_latency = statistics.median(latencies)
                p95_latency = statistics.quantiles(latencies, n=20)[18]  # 95th percentile

                print(f"\n✅ 统计结果 (n={len(latencies)}):")
                print(f"   平均时延: {avg_latency:.2f} ms")
                print(f"   中位数:   {median_latency:.2f} ms")
                print(f"   最小值:   {min_latency:.2f} ms")
                print(f"   最大值:   {max_latency:.2f} ms")
                print(f"   P95:      {p95_latency:.2f} ms")

                # 验收标准
                if scale == 100 and avg_latency > 50:
                    print(f"   ⚠️  警告：超过验收标准 (50ms)")
                elif scale == 1000 and avg_latency > 100:
                    print(f"   ⚠️  警告：超过验收标准 (100ms)")
                elif scale == 10000 and avg_latency > 200:
                    print(f"   ⚠️  警告：超过验收标准 (200ms)")
                else:
                    print(f"   ✅ 符合验收标准")
            else:
                print(f"❌ 无有效查询结果")

    print(f"\n{'='*70}")
    print(f"✅ 基准测试完成！")
    print(f"   结果已保存: {output_file}")
    print(f"{'='*70}")

    return 0


def main():
    """主函数"""
    print("🧪 Exp-3: RPC查询时延 vs 数据规模基准测试")
    print("="*70)

    # 测试规模
    scales = [100, 1000, 10000]

    # 运行基准测试
    return run_benchmark(scales)


if __name__ == "__main__":
    sys.exit(main())
