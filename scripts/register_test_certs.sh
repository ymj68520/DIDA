#!/bin/bash
# 使用cast直接调用合约注册凭证

CONTRACT_ADDR="0x5FbDB2315678afecb367f032d93F642f64180aa3"
SK_TOP="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RPC_URL="http://127.0.0.1:8545"

echo "📝 注册测试凭证到合约..."
echo "合约地址: $CONTRACT_ADDR"
echo ""

# 测试凭证1: 192.168.0.0/24
echo "[1/3] 注册 192.168.0.0/24 ..."
cast send $CONTRACT_ADDR \
  "registerCert(bytes32,(string,bytes,uint64,bool),bytes)" \
  0xc89698bea203a611f447fa8df77cd318f3c89ca128aed195f9944d46cb8c0b51 \
  "(192.168.0.0/24,0x0489ac02d35982ac406825a5c536e1bde4e17dad949276b25fecea1a46480c0c01ed509e2ffe649da74a3ac347e5eb635cc7e4229f15aa673990a00a38fd9d5395,$(date -d '+365 days' +%s),false)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  --private-key $SK_TOP \
  --rpc-url $RPC_URL

echo ""
echo "[2/3] 注册 192.168.1.0/24 ..."
cast send $CONTRACT_ADDR \
  "registerCert(bytes32,(string,bytes,uint64,bool),bytes)" \
  0xfe2e18548518fa9ff6f787939068011bfedba06e1c5b4d4ff98ff068a2288261 \
  "(192.168.1.0/24,0x0489ac02d35982ac406825a5c536e1bde4e17dad949276b25fecea1a46480c0c01ed509e2ffe649da74a3ac347e5eb635cc7e4229f15aa673990a00a38fd9d5395,$(date -d '+365 days' +%s),false)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  --private-key $SK_TOP \
  --rpc-url $RPC_URL

echo ""
echo "[3/3] 注册 192.168.2.0/24 ..."
cast send $CONTRACT_ADDR \
  "registerCert(bytes32,(string,bytes,uint64,bool),bytes)" \
  0xbd8f37333174ad887cbc53aedde27102ac04fc28953998a0cde47355b67e239b \
  "(192.168.2.0/24,0x0489ac02d35982ac406825a5c536e1bde4e17dad949276b25fecea1a46480c0c01ed509e2ffe649da74a3ac347e5eb635cc7e4229f15aa673990a00a38fd9d5395,$(date -d '+365 days' +%s),false)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  --private-key $SK_TOP \
  --rpc-url $RPC_URL

echo ""
echo "✅ 凭证注册完成！"
