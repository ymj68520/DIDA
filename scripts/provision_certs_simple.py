#!/usr/bin/env python3
"""
简化版凭证生成脚本 - 不依赖web3库

使用cast命令来与区块链交互
"""

import os
import sys
import json
import subprocess
from pathlib import Path
from datetime import datetime, timedelta
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.backends import default_backend
import secrets

PROJECT_ROOT = Path(__file__).parent.parent
CONFIG_DIR = PROJECT_ROOT / "config"
KEYGEN_DIR = PROJECT_ROOT / "scripts" / "keygen"

def load_private_key(key_file):
    """从文件加载私钥"""
    with open(KEYGEN_DIR / key_file) as f:
        for line in f:
            line = line.strip()
            if line.startswith('0x'):
                return line
    raise ValueError(f"无法从 {key_file} 读取私钥")

def load_public_key(key_file):
    """从文件加载公钥"""
    with open(KEYGEN_DIR / key_file) as f:
        for line in f:
            line = line.strip()
            if line.startswith('0x'):
                return line
    raise ValueError(f"无法从 {key_file} 读取公钥")

def generate_cert_ip(ip_prefix, pk_sub_hex):
    """生成Cert_IP结构"""
    expiration = int((datetime.now() + timedelta(days=365)).timestamp())
    return {
        'ipPrefix': ip_prefix,
        'publicKey': pk_sub_hex,
        'expiration': expiration,
        'isRevoked': False
    }

def compute_cert_hash(cert_ip):
    """计算Cert_IP的哈希"""
    cert_json = json.dumps(cert_ip, sort_keys=True).encode()
    import hashlib
    return hashlib.sha3_256(cert_json).hexdigest()

def sign_with_sk_top(sk_top_hex, message_hash):
    """使用SK_Top签名"""
    # 将十六进制私钥转换为字节
    sk_bytes = bytes.fromhex(sk_top_hex.replace('0x', ''))

    # 生成私钥对象
    private_key = ec.derive_private_key(
        int.from_bytes(sk_bytes, 'big'),
        ec.SECP256K1(),
        default_backend()
    )

    # 签名
    signature = private_key.sign(
        bytes.fromhex(message_hash),
        ec.ECDSA(hashes.SHA256())
    )

    return '0x' + signature.hex()

def call_contract_register(sk_top, tx_id, cert_ip, sig_top, contract_addr):
    """使用cast调用合约注册函数"""
    # 函数选择器：registerCert(bytes32,(string,bytes,uint64,bool),bytes)
    # 这需要正确的ABI编码

    # 简化：使用cast send命令
    cmd = [
        'cast', 'send',
        contract_addr,
        'registerCert(bytes32,(string,bytes,uint64,bool),bytes)',
        tx_id,
        f"({cert_ip['ipPrefix']},{cert_ip['publicKey']},{cert_ip['expiration']},{str(cert_ip['isRevoked']).lower()})",
        sig_top,
        '--private-key', sk_top,
        '--rpc-url', 'http://127.0.0.1:8545'
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            print(f"✅ 合约调用成功: {result.stdout.strip()}")
            return result.stdout.strip()
        else:
            print(f"❌ 合约调用失败: {result.stderr}")
            return None
    except Exception as e:
        print(f"❌ 调用异常: {e}")
        return None

def generate_sig_sub(sk_sub_hex, ip, tx_id):
    """生成Sig_Sub（节点对IP||TxID的签名）"""
    sk_bytes = bytes.fromhex(sk_sub_hex.replace('0x', ''))
    private_key = ec.derive_private_key(
        int.from_bytes(sk_bytes, 'big'),
        ec.SECP256K1(),
        default_backend()
    )

    message = f"{ip}:{tx_id}".encode()
    signature = private_key.sign(message, ec.ECDSA(hashes.SHA256()))
    return '0x' + signature.hex()

def update_cert_manifest(cert_record):
    """更新证书清单"""
    manifest_path = CONFIG_DIR / "cert_manifest.json"

    if manifest_path.exists():
        with open(manifest_path) as f:
            manifest = json.load(f)
    else:
        manifest = {
            "version": "1.0",
            "generated_at": "",
            "total_certs": 0,
            "certificates": []
        }

    manifest['certificates'].append(cert_record)
    manifest['total_certs'] = len(manifest['certificates'])
    manifest['generated_at'] = datetime.now().isoformat()

    with open(manifest_path, 'w') as f:
        json.dump(manifest, f, indent=2)

    print(f"✅ 证书清单已更新: {manifest_path}")

def main():
    print("🔧 DIDA简化凭证生成器")
    print("="*70)

    # 加载密钥
    print("\n📋 加载密钥...")
    sk_top = load_private_key("sk_top.txt")
    pk_sub = load_public_key("pk_sub.txt")
    sk_sub = load_private_key("sk_sub.txt")

    # 加载合约地址
    with open(CONFIG_DIR / "contract.env") as f:
        contract_addr = None
        for line in f:
            if line.startswith("CONTRACT_ADDR="):
                contract_addr = line.split("=")[1].strip()
                break

    if not contract_addr:
        print("❌ 未找到合约地址")
        return 1

    print(f"✅ 合约地址: {contract_addr}")

    # 生成3个测试凭证
    print("\n🚀 生成3个测试凭证...")
    for i in range(3):
        ip_prefix = f"192.168.{i}.0/24"
        ip_addr = f"192.168.{i}.1"

        # 生成TxID
        import hashlib
        tx_id_input = f"{ip_prefix}:{i}".encode()
        tx_id = '0x' + hashlib.sha3_256(tx_id_input).hexdigest()

        print(f"\n[{i+1}/3] 生成凭证: {ip_prefix}")
        print(f"  TxID: {tx_id}")

        # 生成Cert_IP
        cert_ip = generate_cert_ip(ip_prefix, pk_sub)

        # 计算哈希并签名
        cert_hash = compute_cert_hash(cert_ip)
        sig_top = sign_with_sk_top(sk_top, cert_hash)
        print(f"  Sig_Top: {sig_top[:32]}...")

        # 调用合约注册
        tx_hash = call_contract_register(sk_top, tx_id, cert_ip, sig_top, contract_addr)

        if tx_hash:
            # 生成Sig_Sub
            sig_sub = generate_sig_sub(sk_sub, ip_addr, tx_id)
            print(f"  Sig_Sub: {sig_sub[:32]}...")

            # 更新清单
            cert_record = {
                'ip_prefix': ip_prefix,
                'tx_id': tx_id,
                'sig_sub': sig_sub,
                'expiration': cert_ip['expiration'],
                'pk_sub': pk_sub
            }
            update_cert_manifest(cert_record)

    print("\n✅ 凭证生成完成！")
    return 0

if __name__ == "__main__":
    sys.exit(main())
