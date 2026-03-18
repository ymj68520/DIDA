#!/usr/bin/env python3
"""
批量凭证生成脚本 - DIDA系统 M2阶段

功能：
1. 批量生成IP凭证（10,000条）
2. 离线签名（使用SK_Top）
3. 批量调用合约registerCertBatch()
4. 生成cert_manifest.json

优化：
- 使用多进程并行签名
- 批量上链（每笔交易100条）
- 进度条显示

依赖：
    pip install tqdm

使用方法：
    # 生成10,000条凭证，批量上链
    python3 scripts/bulk_generate_certs.py --count 10000 --batch-size 100

    # 仅生成不上链（测试）
    python3 scripts/bulk_generate_certs.py --count 100 --dry-run
"""

import os
import sys
import json
import argparse
import subprocess
from pathlib import Path
from datetime import datetime, timedelta
from multiprocessing import Pool, cpu_count
from tqdm import tqdm
import secrets
import hashlib

# 项目路径
PROJECT_ROOT = Path(__file__).parent.parent
CONFIG_DIR = PROJECT_ROOT / "config"
KEYGEN_DIR = PROJECT_ROOT / "scripts" / "keygen"


def load_private_key(key_file):
    """从文件加载私钥"""
    with open(KEYGEN_DIR / key_file) as f:
        for line in f:
            line = line.strip()
            if line.startswith('0x') and len(line) == 66:  # 0x + 64 hex chars
                return line
    raise ValueError(f"无法从 {key_file} 读取私钥")


def load_public_key(key_file):
    """从文件加载公钥"""
    with open(KEYGEN_DIR / key_file) as f:
        for line in f:
            line = line.strip()
            if line.startswith('0x') and len(line) == 132:  # 0x + 130 hex chars (65 bytes)
                return line
    raise ValueError(f"无法从 {key_file} 读取公钥")


def generate_tx_id(ip_prefix, index):
    """
    生成TxID（keccak256(ipPrefix + nonce)）

    Args:
        ip_prefix: IP前缀
        index: 索引/nonce

    Returns:
        32字节TxID（十六进制字符串，0x前缀）
    """
    data = f"{ip_prefix}:{index}".encode()
    tx_id = hashlib.sha3_256(data).hexdigest()
    return '0x' + tx_id


def generate_cert_record(index, ip_prefix, pk_sub, expiration_timestamp, sk_top):
    """
    生成单个凭证记录（含签名）

    Args:
        index: 索引
        ip_prefix: IP前缀
        pk_sub: 节点公钥
        expiration_timestamp: 过期时间戳
        sk_top: 顶级权威私钥

    Returns:
        凭证记录字典
    """
    # 生成TxID
    tx_id = generate_tx_id(ip_prefix, index)

    # 构造Cert_IP
    cert_ip = {
        'ip_prefix': ip_prefix,
        'public_key': pk_sub,
        'expiration': expiration_timestamp,
        'is_revoked': False
    }

    # 计算Cert_IP哈希
    cert_json = json.dumps(cert_ip, sort_keys=True).encode()
    cert_hash = hashlib.sha3_256(cert_json).hexdigest()

    # 使用SK_Top签名（这里简化为填充）
    # TODO: 实际应该使用真实的ECDSA签名
    sig_top = "0x" + "00" * 64  # 128个零（占位符）

    return {
        'index': index,
        'tx_id': tx_id,
        'ip_prefix': ip_prefix,
        'pk_sub': pk_sub,
        'expiration': expiration_timestamp,
        'sig_top': sig_top,
        'cert_ip': cert_ip
    }


def generate_cert_records_batch(start_index, count, pk_sub, sk_top):
    """
    批量生成凭证记录

    Args:
        start_index: 起始索引
        count: 数量
        pk_sub: 节点公钥
        sk_top: 顶级权威私钥

    Returns:
        凭证记录列表
    """
    records = []
    expiration_ts = int((datetime.now() + timedelta(days=365)).timestamp())

    for i in range(start_index, start_index + count):
        # 生成IP前缀：10.0.0.0/8, 10.0.1.0/24, 10.0.2.0/24, ...
        if i < 1:
            ip_prefix = "10.0.0.0/8"
        else:
            # 第2个开始使用 /24 子网
            subnet_id = (i - 1) // 256
            host_id = (i - 1) % 256
            ip_prefix = f"10.{subnet_id}.{host_id}.0/24"

        record = generate_cert_record(i, ip_prefix, pk_sub, expiration, sk_top)
        records.append(record)

    return records


def register_batch_on_chain(contract_addr, tx_ids, ip_prefixes, pk_sub, expirations, sig_tops):
    """
    在链上批量注册凭证

    Args:
        contract_addr: 合约地址
        tx_ids: TxID列表
        ip_prefixes: IP前缀列表
        pk_sub: 公钥
        expirations: 过期时间列表
        sig_tops: 签名列表

    Returns:
        交易哈希
    """
    # 使用cast命令批量注册
    tx_ids_str = "[" + ",".join(tx_ids) + "]"

    cert_ips = []
    for i in range(len(ip_prefixes)):
        cert_ips.append(f"({ip_prefixes[i]},{pk_sub},{expirations[i]},false)")
    cert_ips_str = "[" + ",".join(cert_ips) + "]"

    sig_tops_str = "[" + ",".join(sig_tops) + "]"

    cmd = [
        "cast", "send", contract_addr,
        "registerCertBatch(bytes32[],(string,bytes,uint64,bool)[],bytes[])",
        tx_ids_str,
        cert_ips_str,
        sig_tops_str,
        "--private-key", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
        "--rpc-url", "http://127.0.0.1:8545"
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            print(f"⚠️  批量注册失败: {result.stderr}")
            return None

        # 提取交易哈希
        for line in result.stdout.split('\n'):
            if 'transactionHash' in line:
                return line.split()[-1].strip()

        return None
    except subprocess.TimeoutExpired:
        print("❌ 批量注册超时")
        return None


def main():
    parser = argparse.ArgumentParser(description='DIDA批量凭证生成脚本')
    parser.add_argument('--count', type=int, default=10000, help='生成的凭证数量')
    parser.add_argument('--batch-size', type=int, default=100, help='批量上链的批次大小')
    parser.add_argument('--dry-run', action='store_true', help='仅生成不上链')
    parser.add_argument('--output', type=str, help='输出JSON文件路径')

    args = parser.parse_args()

    print("🚀 DIDA批量凭证生成器")
    print("="*70)
    print(f"📋 配置:")
    print(f"   凭证数量: {args.count:,}")
    print(f"   批次大小: {args.batch_size}")
    print(f"   上链模式: {'否 (dry-run)' if args.dry_run else '是'}")
    print("")

    # 加载密钥
    print("📋 加载密钥...")
    try:
        pk_sub = load_public_key("pk_sub.txt")
        sk_top = load_private_key("sk_top.txt")
        print("✅ 密钥加载完成")
    except Exception as e:
        print(f"❌ 密钥加载失败: {e}")
        print("请先运行: python3 scripts/keygen/generate_keys.py")
        return 1

    # 加载合约配置
    with open(CONFIG_DIR / "contract.env") as f:
        config = {}
        for line in f:
            if '=' in line and not line.strip().startswith('#'):
                key, value = line.strip().split('=', 1)
                config[key] = value.strip()

    contract_addr = config.get('CONTRACT_ADDR')
    if not contract_addr:
        print("❌ CONTRACT_ADDR未设置")
        return 1

    print(f"✅ 合约地址: {contract_addr}")
    print("")

    # 生成凭证
    print(f"🔨 生成 {args.count:,} 条凭证...")

    all_records = []
    batch_size = args.batch_size
    expiration_timestamp = int((datetime.now() + timedelta(days=365)).timestamp()))

    # 使用多进程并行生成
    with Pool(processes=min(cpu_count(), 4)) as pool:
        tasks = []
        for start in range(0, args.count, batch_size):
            count = min(batch_size, args.count - start)
            tasks.append((start, count, pk_sub, sk_top))

        results = list(tqdm(
            pool.starmap(generate_cert_records_batch, tasks),
            total=len(tasks),
            desc="生成凭证",
            unit="批次"
        ))

        for batch_records in results:
            all_records.extend(batch_records)

    print(f"✅ 已生成 {len(all_records):,} 条凭证")

    # 批量上链
    if not args.dry_run:
        print(f"\n📝 批量上链到合约...")
        print(f"   批次大小: {batch_size}")
        print(f"   总批次数: {(len(all_records) + batch_size - 1) // batch_size}")
        print("")

        successful_txs = []
        for i in tqdm(range(0, len(all_records), batch_size), desc="上链进度"):
            batch = all_records[i:i+batch_size]

            tx_ids = [r['tx_id'] for r in batch]
            ip_prefixes = [r['ip_prefix'] for r in batch]
            expirations = [r['expiration'] for r in batch]
            sig_tops = [r['sig_top'] for r in batch]

            tx_hash = register_batch_on_chain(
                contract_addr, tx_ids, ip_prefixes, pk_sub, expirations, sig_tops
            )

            if tx_hash:
                successful_txs.append(tx_hash)

        print(f"\n✅ 成功上链 {len(successful_txs)} 批次")

    # 保存到文件
    manifest = {
        "version": "1.0",
        "generated_at": datetime.now().isoformat(),
        "total_certs": len(all_records),
        "certificates": [
            {
                "ip_prefix": r['ip_prefix'],
                "tx_id": r['tx_id'],
                "sig_sub": "0x" + "00" * 64,  # 占位符
                "expiration": r['expiration'],
                "pk_sub": r['pk_sub']
            }
            for r in all_records
        ]
    }

    output_file = args.output or (CONFIG_DIR / "cert_manifest.json")
    with open(output_file, 'w') as f:
        json.dump(manifest, f, indent=2)

    print(f"✅ 证书清单已保存: {output_file}")
    print(f"   包含 {len(all_records):,} 条凭证")

    return 0


if __name__ == "__main__":
    sys.exit(main())
