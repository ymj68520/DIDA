#!/usr/bin/env python3
"""
创建测试证书清单（用于BIND9 zone生成）
"""

import json
from pathlib import Path
from datetime import datetime, timedelta

CONFIG_DIR = Path(__file__).parent.parent / "config"

def create_test_manifest():
    """创建测试证书清单"""

    # 示例公钥（从keygen/pk_sub.txt读取）
    pk_sub = "0x0489ac02d35982ac406825a5c536e1bde4e17dad949276b25fecea1a46480c0c01ed509e2ffe649da74a3ac347e5eb635cc7e4229f15aa673990a00a38fd9d5395"

    # 计算过期时间（365天后）
    expiration = int((datetime.now() + timedelta(days=365)).timestamp())

    # 生成Sig_Sub（这里是简化版，实际应该用SK_Sub签名）
    # 为了测试，使用固定的假签名
    sig_sub = "0x" + "00" * 64  # 128个十六进制字符 = 64字节

    certificates = [
        {
            "ip_prefix": "192.168.0.0/24",
            "tx_id": "0xc89698bea203a611f447fa8df77cd318f3c89ca128aed195f9944d46cb8c0b51",
            "sig_sub": sig_sub,
            "expiration": expiration,
            "pk_sub": pk_sub
        },
        {
            "ip_prefix": "192.168.1.0/24",
            "tx_id": "0xfe2e18548518fa9ff6f787939068011bfedba06e1c5b4d4ff98ff068a2288261",
            "sig_sub": sig_sub,
            "expiration": expiration,
            "pk_sub": pk_sub
        },
        {
            "ip_prefix": "192.168.2.0/24",
            "tx_id": "0xbd8f37333174ad887cbc53aedde27102ac04fc28953998a0cde47355b67e239b",
            "sig_sub": sig_sub,
            "expiration": expiration,
            "pk_sub": pk_sub
        }
    ]

    manifest = {
        "version": "1.0",
        "generated_at": datetime.now().isoformat(),
        "total_certs": len(certificates),
        "certificates": certificates
    }

    # 保存到文件
    manifest_path = CONFIG_DIR / "cert_manifest.json"
    with open(manifest_path, 'w') as f:
        json.dump(manifest, f, indent=2)

    print(f"✅ 证书清单已生成: {manifest_path}")
    print(f"   包含 {len(certificates)} 个测试凭证")

    return manifest

if __name__ == "__main__":
    create_test_manifest()
