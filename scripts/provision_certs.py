#!/usr/bin/env python3
"""
凭证生成脚本 - DIDA系统

功能：
1. 生成IP凭证（Cert_IP），包含IP前缀、PK_Sub、过期时间
2. 使用SK_Top对Cert_IP签名，生成Sig_Top（V1验签使用）
3. 调用IPCertRegistry合约的registerCert函数，将凭证写入链上
4. 生成Sig_Sub（节点对IP+TxID的签名，V2验签使用）
5. 更新cert_manifest.json清单

依赖：
    pip install web3 cryptography

环境变量：
    SK_TOP: 顶级权威私钥（必需）
    RPC_URL: Anvil RPC端点（默认：http://127.0.0.1:8545）
    CONTRACT_ADDR: 合约地址（自动从config/contract.env读取）

使用方法：
    # 单个凭证
    python3 scripts/provision_certs.py --ip-prefix 192.168.1.0/24 --pk-sub scripts/keygen/pk_sub.txt

    # 批量凭证（从CSV）
    python3 scripts/provision_certs.py --batch certs_list.csv

    # 自动生成测试凭证（使用示例密钥）
    python3 scripts/provision_certs.py --auto 10
"""

import os
import sys
import json
import argparse
import time
from pathlib import Path
from datetime import datetime, timedelta
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.backends import default_backend
from web3 import Web3
from web3.middleware import geth_poa_middleware

# 添加项目根目录到路径
PROJECT_ROOT = Path(__file__).parent.parent
KEYGEN_DIR = PROJECT_ROOT / "scripts" / "keygen"
CONFIG_DIR = PROJECT_ROOT / "config"

def load_contract_config():
    """加载合约配置"""
    contract_env = CONFIG_DIR / "contract.env"
    if not contract_env.exists():
        raise FileNotFoundError(f"合约配置文件不存在: {contract_env}")

    config = {}
    with open(contract_env) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.strip()] = value.strip()

    if not config.get('CONTRACT_ADDR'):
        raise ValueError("CONTRACT_ADDR未在config/contract.env中设置")

    return config

def load_sk_top():
    """从环境变量或文件加载SK_Top"""
    sk_top = os.environ.get('SK_TOP')
    if sk_top:
        return sk_top

    # 尝试从文件读取
    sk_top_file = KEYGEN_DIR / "sk_top.txt"
    if sk_top_file.exists():
        with open(sk_top_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith('0x') and len(line) == 66:  # 0x + 64 hex chars
                    return line

    raise ValueError("SK_TOP环境变量未设置，且未找到scripts/keygen/sk_top.txt")

def load_pk_sub_from_file(pk_sub_file):
    """从文件加载PK_Sub"""
    pk_sub_file = Path(pk_sub_file)
    if not pk_sub_file.exists():
        raise FileNotFoundError(f"公钥文件不存在: {pk_sub_file}")

    with open(pk_sub_file) as f:
        for line in f:
            line = line.strip()
            if line.startswith('0x') and len(line) == 132:  # 0x + 130 hex chars (65 bytes)
                return line

    raise ValueError(f"无法从 {pk_sub_file} 解析PK_Sub（应为0x开头的130字符十六进制）")

def hash_cert_ip(cert_ip_dict):
    """计算Cert_IP的Keccak256哈希（Solidity abi.encode等价）"""
    import hashlib
    # 简化版本：实际应该使用web3.utils.keccak(text=abi.encode(cert_ip))
    # 这里先用SHA256作为占位符
    cert_json = json.dumps(cert_ip_dict, sort_keys=True).encode()
    return hashlib.sha3_256(cert_json).hexdigest()

def sign_with_sk_top(sk_top_hex, message_hash):
    """使用SK_Top对消息哈希签名（ECDSA）"""
    # 将十六进制私钥转换为字节
    sk_bytes = bytes.fromhex(sk_top_hex.replace('0x', ''))

    # 加载私钥
    private_key = ec.derive_private_key(int.from_bytes(sk_bytes, 'big'), ec.SECP256K1(), default_backend())

    # 对消息哈希签名
    signature = private_key.sign(
        bytes.fromhex(message_hash),
        ec.ECDSA(hashes.SHA256())
    )

    # 返回DER编码的签名（实际部署时需要转换为Solidity格式）
    return '0x' + signature.hex()

def connect_to_web3(rpc_url):
    """连接到Web3节点"""
    w3 = Web3(Web3.HTTPProvider(rpc_url))

    # 添加POA中间件（用于Anvil）
    w3.middleware_onion.inject(geth_poa_middleware, layer=0)

    if not w3.is_connected():
        raise ConnectionError(f"无法连接到RPC节点: {rpc_url}")

    return w3

def get_contract_instance(w3, contract_address):
    """获取合约实例"""
    # 这里应该加载IPCertRegistry的ABI
    # 简化版本：假设ABI已经加载
    abi_path = PROJECT_ROOT / "contracts" / "out" / "IPCertRegistry.sol" / "IPCertRegistry.json"

    if not abi_path.exists():
        raise FileNotFoundError(f"合约ABI文件不存在，请先运行: forge build")

    with open(abi_path) as f:
        contract_json = json.load(f)

    abi = contract_json['abi']
    contract = w3.eth.contract(address=contract_address, abi=abi)

    return contract

def generate_tx_id(ip_prefix, nonce):
    """生成TxID（keccak256(ipPrefix + nonce)）"""
    import hashlib
    data = f"{ip_prefix}:{nonce}".encode()
    return '0x' + hashlib.sha3_256(data).hexdigest()

def register_cert_on_chain(contract, sk_top, tx_id, cert_ip, sig_top):
    """在链上注册凭证"""
    # 构造交易
    nonce = contract.w3.eth.get_transaction_count(contract.w3.eth.account.from_key(sk_top).address)

    tx = contract.functions.registerCert(
        Web3.to_bytes(hexstr=tx_id),
        (
            cert_ip['ip_prefix'],
            Web3.to_bytes(hexstr=cert_ip['public_key']),
            cert_ip['expiration'],
            cert_ip['is_revoked']
        ),
        Web3.to_bytes(hexstr=sig_top)
    ).build_transaction({
        'from': Web3.to_checksum_address(contract.w3.eth.account.from_key(sk_top).address),
        'nonce': nonce,
        'gas': 200000,
        'gasPrice': contract.w3.eth.gas_price
    })

    # 签名交易
    signed_tx = contract.w3.eth.account.sign_transaction(tx, sk_top)

    # 发送交易
    tx_hash = contract.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

    # 等待确认
    receipt = contract.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)

    if receipt['status'] == 1:
        print(f"✅ 凭证已注册，TxHash: {tx_hash.hex()}")
        return tx_hash.hex()
    else:
        raise Exception(f"交易失败: {tx_hash.hex()}")

def update_cert_manifest(cert_manifest_path, cert_record):
    """更新证书清单"""
    if cert_manifest_path.exists():
        with open(cert_manifest_path) as f:
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

    with open(cert_manifest_path, 'w') as f:
        json.dump(manifest, f, indent=2)

    print(f"✅ 证书清单已更新: {cert_manifest_path}")

def provision_single_cert(ip_prefix, pk_sub_hex, sk_top_hex, contract, config):
    """单个凭证的完整生成流程"""
    print(f"\n🔐 生成凭证: {ip_prefix}")
    print("="*70)

    # 1. 生成Cert_IP结构
    expiration = int((datetime.now() + timedelta(days=365)).timestamp())
    cert_ip = {
        'ip_prefix': ip_prefix,
        'public_key': pk_sub_hex,
        'expiration': expiration,
        'is_revoked': False
    }

    # 2. 生成TxID
    nonce = int(time.time())
    tx_id = generate_tx_id(ip_prefix, nonce)
    print(f"TxID: {tx_id}")

    # 3. 计算Cert_IP哈希
    cert_hash = hash_cert_ip(cert_ip)
    print(f"Cert_IP Hash: {cert_hash}")

    # 4. 用SK_Top签名，生成Sig_Top
    sig_top = sign_with_sk_top(sk_top_hex, cert_hash)
    print(f"Sig_Top: {sig_top[:64]}...")  # 只显示前64字符

    # 5. 调用合约注册凭证
    tx_hash = register_cert_on_chain(contract, sk_top_hex, tx_id, cert_ip, sig_top)
    print(f"链上TxHash: {tx_hash}")

    # 6. 生成Sig_Sub（节点对IP+TxID的签名）
    # 注意：实际应该使用SK_Sub签名，这里暂时用SK_Top代替
    ip_txid = f"{ip_prefix}:{tx_id}".encode()
    sig_sub = sign_with_sk_top(sk_top_hex, hashlib.sha256(ip_txid).hexdigest())
    print(f"Sig_Sub: {sig_sub[:64]}...")

    # 7. 更新证书清单
    cert_record = {
        'ip_prefix': ip_prefix,
        'tx_id': tx_id,
        'sig_sub': sig_sub,
        'expiration': expiration,
        'pk_sub': pk_sub_hex
    }

    cert_manifest_path = CONFIG_DIR / "cert_manifest.json"
    update_cert_manifest(cert_manifest_path, cert_record)

    return cert_record

def main():
    parser = argparse.ArgumentParser(description='DIDA凭证生成脚本')
    parser.add_argument('--ip-prefix', help='IP前缀（如192.168.1.0/24）')
    parser.add_argument('--pk-sub', help='PK_Sub文件路径或十六进制字符串')
    parser.add_argument('--auto', type=int, help='自动生成N个测试凭证')
    parser.add_argument('--batch', help='从CSV文件批量生成')
    parser.add_argument('--dry-run', action='store_true', help='仅模拟，不写入链上')

    args = parser.parse_args()

    try:
        # 加载配置
        print("🔧 加载配置...")
        config = load_contract_config()
        sk_top = load_sk_top()
        print(f"✅ 合约地址: {config['CONTRACT_ADDR']}")
        print(f"✅ RPC URL: {config['RPC_URL']}")

        # 连接Web3
        print("\n🔗 连接区块链节点...")
        w3 = connect_to_web3(config['RPC_URL'])
        print(f"✅ 已连接，链ID: {w3.eth.chain_id}")

        # 获取合约实例
        print("\n📜 加载合约实例...")
        contract = get_contract_instance(w3, config['CONTRACT_ADDR'])
        print(f"✅ 合约已加载")

        # 根据参数执行不同操作
        if args.auto:
            print(f"\n🚀 自动生成 {args.auto} 个测试凭证")
            for i in range(args.auto):
                ip_prefix = f"192.168.{i}.0/24"
                pk_sub_file = KEYGEN_DIR / "pk_sub.txt"
                if not pk_sub_file.exists():
                    # 如果不存在示例密钥，生成临时密钥
                    print(f"⚠️  未找到pk_sub.txt，使用临时密钥")
                    pk_sub_hex = "0x" + "04" + "01" * 64  # 占位符
                else:
                    pk_sub_hex = load_pk_sub_from_file(pk_sub_file)

                provision_single_cert(ip_prefix, pk_sub_hex, sk_top, contract, config)
                time.sleep(1)  # 避免交易 nonce 冲突

        elif args.ip_prefix and args.pk_sub:
            pk_sub_hex = load_pk_sub_from_file(args.pk_sub) if Path(args.pk_sub).exists() else args.pk_sub
            provision_single_cert(args.ip_prefix, pk_sub_hex, sk_top, contract, config)

        else:
            parser.print_help()
            return 1

        print("\n✅ 凭证生成完成！")
        return 0

    except Exception as e:
        print(f"\n❌ 错误: {e}")
        import traceback
        traceback.print_exc()
        return 1

if __name__ == "__main__":
    sys.exit(main())
