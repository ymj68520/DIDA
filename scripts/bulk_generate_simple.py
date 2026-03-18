#!/usr/bin/env python3
"""
批量凭证生成脚本 - 简化版
"""

import os
import sys
import json
import argparse
import secrets
import hashlib
from datetime import datetime, timedelta
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
CONFIG_DIR = PROJECT_ROOT / "config"


def generate_tx_id(ip_prefix, index):
    """生成TxID"""
    data = f"{ip_prefix}:{index}".encode()
    return '0x' + hashlib.sha3_256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description='批量凭证生成')
    parser.add_argument('--count', type=int, default=10000, help='凭证数量')
    parser.add_argument('--batch-size', type=int, default=100, help='批次大小')
    parser.add_argument('--dry-run', action='store_true', help='不上链')

    args = parser.parse_args()

    print(f"🚀 生成 {args.count:,} 条凭证...")

    # 加载公钥
    with open(PROJECT_ROOT / "scripts/keygen/pk_sub.txt") as f:
        pk_sub = f.read().strip()

    expiration_ts = int((datetime.now() + timedelta(days=365)).timestamp())

    certificates = []

    for i in range(args.count):
        if i < 1:
            ip_prefix = "10.0.0.0/8"
        else:
            subnet = (i - 1) // 256
            host = (i - 1) % 256
            ip_prefix = f"10.{subnet}.{host}.0/24"

        tx_id = generate_tx_id(ip_prefix, i)

        cert = {
            "ip_prefix": ip_prefix,
            "tx_id": tx_id,
            "sig_sub": "0x" + "00" * 64,
            "expiration": expiration_ts,
            "pk_sub": pk_sub
        }

        certificates.append(cert)

        if (i + 1) % 1000 == 0:
            print(f"  进度: {i+1:,} / {args.count:,}")

    # 保存清单
    manifest = {
        "version": "1.0",
        "generated_at": datetime.now().isoformat(),
        "total_certs": len(certificates),
        "certificates": certificates
    }

    output_file = CONFIG_DIR / "cert_manifest.json"
    with open(output_file, 'w') as f:
        json.dump(manifest, f, indent=2)

    print(f"✅ 完成！已生成 {len(certificates):,} 条凭证")
    print(f"   清单已保存: {output_file}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
