#!/usr/bin/env python3
"""
IPCertRegistry合约交互工具类

简化与IPCertRegistry合约的交互，提供：
- 批量注册凭证
- 查询凭证记录
- 批量查询
- 验证凭证有效性
"""

import subprocess
import json
from typing import List, Dict, Optional
from pathlib import Path


class IPCertRegistryClient:
    """IPCertRegistry合约客户端"""

    def __init__(
        self,
        contract_addr: str,
        rpc_url: str = "http://127.0.0.1:8545",
        private_key: Optional[str] = None
    ):
        """
        初始化合约客户端

        Args:
            contract_addr: 合约地址
            rpc_url: RPC端点
            private_key: 私钥（用于写操作）
        """
        self.contract_addr = contract_addr
        self.rpc_url = rpc_url
        self.private_key = private_key or "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

    def _run_cast(self, args: List[str]) -> str:
        """执行cast命令并返回输出"""
        cmd = ["cast"] + args
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30,
                check=False
            )
            if result.returncode != 0:
                raise Exception(f"Cast command failed: {result.stderr}")
            return result.stdout.strip()
        except subprocess.TimeoutExpired:
            raise Exception("Cast command timeout")

    def get_record(self, tx_id: str) -> Dict:
        """
        查询单个凭证记录

        Args:
            tx_id: 交易ID（32字节十六进制）

        Returns:
            凭证记录字典
        """
        # 调用getRecord(bytes32)
        output = self._run_cast([
            "call", self.contract_addr,
            "getRecord(bytes32,((string,bytes,uint64,bool),bytes))",
            tx_id,
            "--rpc-url", self.rpc_url
        ])

        # 解析输出（简化版，实际需要完整ABI解码）
        return {
            "tx_id": tx_id,
            "raw": output
        }

    def get_records_batch(self, tx_ids: List[str]) -> List[Dict]:
        """
        批量查询凭证记录

        Args:
            tx_ids: 交易ID列表

        Returns:
            凭证记录列表
        """
        records = []
        for tx_id in tx_ids:
            try:
                record = self.get_record(tx_id)
                records.append(record)
            except Exception as e:
                print(f"⚠️  查询失败 {tx_id[:16]}...: {e}")
        return records

    def is_valid(self, tx_id: str) -> bool:
        """
        检查凭证是否有效

        Args:
            tx_id: 交易ID

        Returns:
            True表示有效，False表示无效
        """
        output = self._run_cast([
            "call", self.contract_addr,
            "isValid(bytes32,bool)",
            tx_id,
            "--rpc-url", self.rpc_url
        ])
        return "true" in output.lower()

    def register_cert(
        self,
        tx_id: str,
        ip_prefix: str,
        public_key: str,
        expiration: int,
        sig_top: str
    ) -> str:
        """
        注册单个凭证

        Args:
            tx_id: 交易ID
            ip_prefix: IP前缀
            public_key: 公钥
            expiration: 过期时间戳
            sig_top: 顶级权威签名

        Returns:
            交易哈希
        """
        # 构造CertIP元组
        cert_ip = f"({ip_prefix},{public_key},{expiration},false)"

        output = self._run_cast([
            "send", self.contract_addr,
            "registerCert(bytes32,(string,bytes,uint64,bool),bytes)",
            tx_id,
            cert_ip,
            sig_top,
            "--private-key", self.private_key,
            "--rpc-url", self.rpc_url
        ])

        # 提取交易哈希
        lines = output.split('\n')
        for line in lines:
            if 'transactionHash' in line or line.startswith('0x'):
                tx_hash = line.split()[-1].strip()
                if len(tx_hash) == 66:  # 0x + 64 hex chars
                    return tx_hash

        raise Exception(f"Failed to extract transaction hash from: {output}")

    def register_cert_batch(
        self,
        tx_ids: List[str],
        ip_prefixes: List[str],
        public_keys: List[str],
        expirations: List[int],
        sig_tops: List[str]
    ) -> str:
        """
        批量注册凭证（Gas优化）

        Args:
            tx_ids: 交易ID列表
            ip_prefixes: IP前缀列表
            public_keys: 公钥列表
            expirations: 过期时间列表
            sig_tops: 签名列表

        Returns:
            交易哈希
        """
        if len(tx_ids) != len(ip_prefixes):
            raise ValueError("tx_ids和ip_prefixes长度不匹配")

        # 构造批量参数
        # 格式：[tx_id1,tx_id2,...], [(ip1,pk1,exp1,false),(ip2,pk2,exp2,false),...], [sig1,sig2,...]
        tx_ids_str = "[" + ",".join(tx_ids) + "]"

        cert_ips = []
        for i in range(len(ip_prefixes)):
            cert_ips.append(f"({ip_prefixes[i]},{public_keys[i]},{expirations[i]},false)")
        cert_ips_str = "[" + ",".join(cert_ips) + "]"

        sig_tops_str = "[" + ",".join(sig_tops) + "]"

        output = self._run_cast([
            "send", self.contract_addr,
            "registerCertBatch(bytes32[],(string,bytes,uint64,bool)[],bytes[])",
            tx_ids_str,
            cert_ips_str,
            sig_tops_str,
            "--private-key", self.private_key,
            "--rpc-url", self.rpc_url
        ])

        # 提取交易哈希
        lines = output.split('\n')
        for line in lines:
            if 'transactionHash' in line:
                parts = line.split()
                for part in parts:
                    if part.startswith('0x') and len(part) == 66:
                        return part

        raise Exception(f"Failed to extract transaction hash from: {output}")

    def get_authority(self) -> str:
        """获取合约authority地址"""
        output = self._run_cast([
            "call", self.contract_addr,
            "authority()",
            "--rpc-url", self.rpc_url
        ])
        return output.strip()

    def revoke_cert(self, tx_id: str) -> str:
        """
        吊销凭证

        Args:
            tx_id: 交易ID

        Returns:
            交易哈希
        """
        output = self._run_cast([
            "send", self.contract_addr,
            "revokeCert(bytes32)",
            tx_id,
            "--private-key", self.private_key,
            "--rpc-url", self.rpc_url
        ])

        # 提取交易哈希
        for line in output.split('\n'):
            if 'transactionHash' in line:
                return line.split()[-1].strip()

        raise Exception(f"Failed to revoke cert: {output}")


def main():
    """测试合约客户端"""
    # 加载配置
    import os
    project_root = Path(__file__).parent.parent
    config_file = project_root / "config" / "contract.env"

    with open(config_file) as f:
        config = {}
        for line in f:
            if '=' in line and not line.strip().startswith('#'):
                key, value = line.strip().split('=', 1)
                config[key] = value.strip()

    contract_addr = config.get('CONTRACT_ADDR')
    rpc_url = config.get('RPC_URL', 'http://127.0.0.1:8545')

    if not contract_addr:
        print("❌ CONTRACT_ADDR未设置")
        return 1

    print(f"🔗 连接到合约: {contract_addr}")

    # 创建客户端
    client = IPCertRegistryClient(contract_addr, rpc_url)

    # 测试1: 获取authority
    print("\n📋 测试：获取authority")
    authority = client.get_authority()
    print(f"✅ Authority: {authority}")

    # 测试2: 查询已注册的凭证
    print("\n📋 测试：查询已注册凭证")
    test_tx_id = "0xc89698bea203a611f447fa8df77cd318f3c89ca128aed195f9944d46cb8c0b51"
    try:
        record = client.get_record(test_tx_id)
        print(f"✅ 凭证记录: {record['raw'][:100]}...")
    except Exception as e:
        print(f"❌ 查询失败: {e}")

    # 测试3: 验证凭证有效性
    print("\n📋 测试：验证凭证有效性")
    try:
        is_valid = client.is_valid(test_tx_id)
        print(f"✅ 凭证有效: {is_valid}")
    except Exception as e:
        print(f"❌ 验证失败: {e}")

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
