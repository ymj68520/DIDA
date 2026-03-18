#!/usr/bin/env python3
"""
密钥生成脚本 - DIDA系统

生成顶级权威密钥对（PK_Top/SK_Top）和节点密钥对（PK_Sub/SK_Sub）

安全警告：
- SK_Top是系统最敏感的密钥，任何拥有者都可以伪造链上凭证
- 本脚本生成的密钥仅用于实验环境
- 生产环境应使用HSM或KMS等硬件安全模块

使用方法：
    python3 scripts/keygen/generate_keys.py

输出：
    scripts/keygen/pk_top.txt      # PK_Top（公钥，写入config/trust_anchor.env）
    scripts/keygen/sk_top.txt      # SK_Top（私钥，设置环境变量SK_TOP）
    scripts/keygen/pk_sub.txt      # PK_Sub（示例节点公钥）
    scripts/keygen/sk_sub.txt      # SK_Sub（示例节点私钥）
"""

import os
import sys
from pathlib import Path
from datetime import datetime
from cryptography.hazmat.primitives.asymmetric import ec as ec_crypto
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend
import secrets

# 添加项目根目录到路径
PROJECT_ROOT = Path(__file__).parent.parent.parent
KEYGEN_DIR = PROJECT_ROOT / "scripts" / "keygen"
CONFIG_DIR = PROJECT_ROOT / "config"

def generate_secp256k1_keypair():
    """
    生成secp256k1密钥对（非压缩格式，65字节公钥）

    Returns:
        tuple: (private_key_hex, public_key_hex)
    """
    # 生成32字节随机私钥
    private_key_bytes = secrets.token_bytes(32)
    sk_hex = "0x" + private_key_bytes.hex()

    # 从私钥生成私钥对象
    private_key = ec_crypto.derive_private_key(
        int.from_bytes(private_key_bytes, 'big'),
        ec_crypto.SECP256K1(),
        default_backend()
    )
    public_key = private_key.public_key()

    # 序列化公钥（非压缩格式，65字节：0x04 + X + Y）
    public_key_bytes = public_key.public_bytes(
        encoding=serialization.Encoding.X962,
        format=serialization.PublicFormat.UncompressedPoint
    )
    pk_hex = "0x" + public_key_bytes.hex()

    return sk_hex, pk_hex

def save_key(filename, key_value, description):
    """保存密钥到文件，设置适当的权限"""
    filepath = KEYGEN_DIR / filename

    with open(filepath, 'w') as f:
        f.write(f"# {description}\n")
        f.write(f"# Generated at: {datetime.now().isoformat()}\n")
        f.write(f"# ⚠️  警告：此文件包含敏感密钥，请勿提交到Git仓库\n")
        f.write(f"\n{key_value}\n")

    # 设置文件权限（仅所有者可读写）
    os.chmod(filepath, 0o600)
    print(f"✅ 已生成: {filepath}")

def update_trust_anchor_env(pk_top_hex):
    """更新config/trust_anchor.env文件，填入PK_Top"""
    env_file = CONFIG_DIR / "trust_anchor.env"
    with open(env_file, 'w') as f:
        f.write("# 信任锚公钥配置\n")
        f.write("# PK_Top: 顶级权威机构的公钥，用于V1验签\n")
        f.write(f"# Generated at: {datetime.now().isoformat()}\n")
        f.write(f"# ⚠️  警告：此文件包含敏感配置，请勿提交到Git仓库\n")
        f.write(f"\nPK_TOP={pk_top_hex}\n")
        f.write("\n# 注意：\n")
        f.write("# 1. PK_Top必须与部署合约时使用的SK_Top对应\n")
        f.write("# 2. PK_Top由scripts/keygen/generate_keys.py生成\n")
        f.write("# 3. 网关启动时从本文件加载PK_Top，不依赖任何网络查询\n")
    print(f"✅ 已更新: {env_file}")

def print_export_instructions(sk_top_hex, sk_sub_hex):
    """打印环境变量导出指令"""
    print("\n" + "="*70)
    print("📋 环境变量设置指令：")
    print("="*70)
    print(f"\n# 临时设置（当前终端会话）：")
    print(f"export SK_TOP={sk_top_hex}")
    print(f"export SK_SUB={sk_sub_hex}")
    print(f"\n# 或永久添加到 ~/.bashrc 或 ~/.zshrc：")
    print(f'echo "export SK_TOP={sk_top_hex}" >> ~/.bashrc')
    print(f'echo "export SK_SUB={sk_sub_hex}" >> ~/.bashrc')
    print("\n" + "="*70)

def main():
    """主函数"""
    print("🔐 DIDA密钥生成器")
    print("="*70)

    # 创建必要的目录
    KEYGEN_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    # 生成顶级权威密钥对
    print("\n[1/2] 生成顶级权威密钥对（PK_Top / SK_Top）...")
    sk_top, pk_top = generate_secp256k1_keypair()
    save_key("pk_top.txt", pk_top, "PK_Top - 顶级权威公钥（用于V1验签）")
    save_key("sk_top.txt", sk_top, "SK_Top - 顶级权威私钥（用于签发链上凭证）")

    # 生成示例节点密钥对
    print("\n[2/2] 生成示例节点密钥对（PK_Sub / SK_Sub）...")
    sk_sub, pk_sub = generate_secp256k1_keypair()
    save_key("pk_sub.txt", pk_sub, "PK_Sub - 示例节点公钥（写入链上Cert_IP）")
    save_key("sk_sub.txt", sk_sub, "SK_Sub - 示例节点私钥（用于生成Sig_Sub）")

    # 更新trust_anchor.env
    update_trust_anchor_env(pk_top)

    # 打印密钥信息
    print("\n" + "="*70)
    print("✅ 密钥生成完成！")
    print("="*70)
    print(f"\nPK_Top (公钥): {pk_top}")
    print(f"SK_Top (私钥): {sk_top}")
    print(f"PK_Sub (公钥): {pk_sub}")
    print(f"SK_Sub (私钥): {sk_sub}")

    # 打印环境变量设置指令
    print_export_instructions(sk_top, sk_sub)

    print("\n⚠️  安全提醒：")
    print("1. scripts/keygen/ 目录中的私钥文件已设置权限为0600")
    print("2. 请勿将sk_top.txt或sk_sub.txt提交到Git仓库")
    print("3. .gitignore已配置忽略scripts/keygen/目录")
    print("4. 在生产环境中，应使用HSM或KMS保护私钥")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n❌ 用户中断")
        sys.exit(1)
    except Exception as e:
        print(f"\n\n❌ 错误: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
