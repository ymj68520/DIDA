#!/bin/bash
#
# NFQUEUE规则配置脚本 - 端口白名单方案

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "🔧 配置NFQUEUE规则（端口白名单方案）"
echo "======================================"
echo ""

# 清除现有规则
echo -e "${YELLOW}清除现有NFQUEUE规则...${NC}"
sudo iptables -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>/dev/null || true
sudo iptables -D INPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>/dev/null || true

echo "  旧规则已清除"

# 配置新规则
echo ""
echo -e "${YELLOW}配置新规则...${NC}"

# OUTPUT链：DNS和RPC端口直接ACCEPT
echo "  配置OUTPUT链规则..."
sudo iptables -A OUTPUT -p tcp --tcp-flags SYN,RST SYN --dport 53 -j ACCEPT
echo -e "    ${GREEN}✅${NC} DNS端口（53）直接ACCEPT"

sudo iptables -A OUTPUT -p tcp --tcp-flags SYN,RST SYN --dport 8545 -j ACCEPT
echo -e "    ${GREEN}✅${NC} RPC端口（8545）直接ACCEPT"

# 其他端口进入NFQUEUE
sudo iptables -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0
echo -e "    ${GREEN}✅${NC} 其他端口进入NFQUEUE"

# INPUT链：DNS和RPC端口直接ACCEPT
echo "  配置INPUT链规则..."
sudo iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN --sport 53 -j ACCEPT
echo -e "    ${GREEN}✅${NC} DNS端口（53）直接ACCEPT"

sudo iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN --sport 8545 -j ACCEPT
echo -e "    ${GREEN}✅${NC} RPC端口（8545）直接ACCEPT"

# 其他端口进入NFQUEUE
sudo iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0
echo -e "    ${GREEN}✅${NC} 其他端口进入NFQUEUE"

echo ""
echo "======================================"
echo -e "${GREEN}✅ NFQUEUE规则配置完成！${NC}"
echo ""
echo "📊 规则说明:"
echo "   - DNS流量（端口53）→ 直接通过，不验证"
echo "   - RPC流量（端口8545）→ 直接通过，不验证"
echo "   - 其他流量→ 进入NFQUEUE，由auth-gateway验证"

echo ""
echo "🌐 本地服务测试:"
echo ""

# 测试Anvil
echo -n "  Anvil RPC: "
if curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://127.0.0.1:8545 > /dev/null 2>&1; then
    echo -e "${GREEN}✅ 正常${NC}"
else
    echo -e "${RED}❌ 失败${NC}"
fi

# 测试BIND9
echo -n "  BIND9 DNS: "
if dig @127.0.0.2 -p 53 example.com +short +time=2 > /dev/null 2>&1; then
    echo -e "${GREEN}✅ 正常${NC}"
else
    echo -e "${RED}❌ 失败${NC}"
fi

echo ""
echo "======================================"
