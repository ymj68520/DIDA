#!/bin/bash
#
# DIDA系统综合验证脚本
#
# 功能：
# - 验证基础设施状态
# - 验证NFQUEUE规则配置
# - 验证白名单配置

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "🔍 DIDA系统综合验证"
echo "======================================"
echo ""

# ========================================
# 1. 验证基础设施
# ========================================
echo -e "${GREEN}[1/3]${NC} 验证基础设施..."

# Anvil状态
echo -n "  Anvil: "
if pgrep -x anvil > /dev/null; then
    echo -e "${GREEN}✅ 运行中${NC} (PID: $(pgrep -x anvil))"

    # 测试RPC连接
    if command -v curl &> /dev/null; then
        if curl -s -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://127.0.0.1:8545 2>/dev/null | grep -q "0x"; then
            echo -e "    ${GREEN}✅ RPC连接正常${NC}"
        else
            echo -e "    ${YELLOW}⚠️  RPC连接测试失败${NC}"
        fi
    fi
else
    echo -e "${RED}❌ 未运行${NC}"
fi

# BIND9状态
echo -n "  BIND9: "
BIND9_RUNNING=false

# 方法1：检查systemctl服务状态
if systemctl is-active --quiet bind9 2>/dev/null; then
    BIND9_RUNNING=true
fi

# 方法2：检查named进程（手动启动的情况）
if ! $BIND9_RUNNING; then
    if pgrep -x named > /dev/null || pgrep -f "named.*-c.*bind9" > /dev/null; then
        BIND9_RUNNING=true
    fi
fi

if $BIND9_RUNNING; then
    echo -e "${GREEN}✅ 运行中${NC}"

    # 测试DNS查询
    if command -v dig &> /dev/null; then
        if dig @127.0.0.2 -p 53 example.com +short +time=1 > /dev/null 2>&1; then
            echo -e "    ${GREEN}✅ DNS查询正常${NC}"
        else
            echo -e "    ${YELLOW}⚠️  DNS查询测试失败${NC}"
        fi
    fi
else
    echo -e "${RED}❌ 未运行${NC}"
    echo -e "    ${YELLOW}💡 提示：运行 'sudo systemctl start bind9' 或检查named进程${NC}"
fi

# 网络仿真状态
echo -n "  网络仿真: "
if sudo tc qdisc show dev lo 2>/dev/null | grep -q "netem"; then
    echo -e "${GREEN}✅ 已配置${NC}"
else
    echo -e "${RED}❌ 未配置${NC}"
fi

echo ""

# ========================================
# 2. 验证NFQUEUE规则
# ========================================
echo -e "${GREEN}[2/3]${NC} 验证NFQUEUE规则..."

# 检查OUTPUT链
echo "  检查OUTPUT链..."
OUTPUT_RULES=$(sudo iptables -L OUTPUT -n --line-numbers 2>/dev/null | grep -E "(ACCEPT|NFQUEUE)" | head -5)
if [ -n "$OUTPUT_RULES" ]; then
    echo -e "$OUTPUT_RULES"

    # 检测方案类型：端口白名单 vs lo接口排除
    HAS_PORT_WHITELIST=false
    HAS_LO_EXCLUSION=false

    # 检查端口白名单规则
    if echo "$OUTPUT_RULES" | grep -q "dpt:53.*ACCEPT" && echo "$OUTPUT_RULES" | grep -q "dpt:8545.*ACCEPT"; then
        HAS_PORT_WHITELIST=true
    fi

    # 检查lo接口排除规则
    if echo "$OUTPUT_RULES" | grep -q "ACCEPT.*lo"; then
        HAS_LO_EXCLUSION=true
    fi

    # 验证并输出结果
    if [ "$HAS_PORT_WHITELIST" = true ]; then
        echo -e "    ${GREEN}✅ 方案：端口白名单${NC}"
        echo -e "    ${GREEN}✅ 规则正确：DNS端口(53)和RPC端口(8545)已白名单${NC}"
    elif [ "$HAS_LO_EXCLUSION" = true ]; then
        echo -e "    ${GREEN}✅ 方案：lo接口排除${NC}"
        echo -e "    ${GREEN}✅ 规则正确：lo接口流量被ACCEPT${NC}"
    else
        echo -e "    ${RED}❌ 规则错误：未找到有效的ACCEPT规则${NC}"
        echo -e "    ${YELLOW}⚠️  既未发现端口白名单，也未发现lo接口排除${NC}"
    fi
else
    echo -e "    ${YELLOW}⚠️  未发现NFQUEUE规则${NC}"
fi

# 检查INPUT链
echo "  检查INPUT链..."
INPUT_RULES=$(sudo iptables -L INPUT -n --line-numbers 2>/dev/null | grep -E "(ACCEPT|NFQUEUE)" | head -5)
if [ -n "$INPUT_RULES" ]; then
    echo -e "$INPUT_RULES"

    # 检测方案类型：端口白名单 vs lo接口排除
    HAS_PORT_WHITELIST=false
    HAS_LO_EXCLUSION=false

    # 检查端口白名单规则
    if echo "$INPUT_RULES" | grep -q "spt:53.*ACCEPT" && echo "$INPUT_RULES" | grep -q "spt:8545.*ACCEPT"; then
        HAS_PORT_WHITELIST=true
    fi

    # 检查lo接口排除规则
    if echo "$INPUT_RULES" | grep -q "ACCEPT.*lo"; then
        HAS_LO_EXCLUSION=true
    fi

    # 验证并输出结果
    if [ "$HAS_PORT_WHITELIST" = true ]; then
        echo -e "    ${GREEN}✅ 方案：端口白名单${NC}"
        echo -e "    ${GREEN}✅ 规则正确：DNS端口(53)和RPC端口(8545)已白名单${NC}"
    elif [ "$HAS_LO_EXCLUSION" = true ]; then
        echo -e "    ${GREEN}✅ 方案：lo接口排除${NC}"
        echo -e "    ${GREEN}✅ 规则正确：lo接口流量被ACCEPT${NC}"
    else
        echo -e "    ${RED}❌ 规则错误：未找到有效的ACCEPT规则${NC}"
        echo -e "    ${YELLOW}⚠️  既未发现端口白名单，也未发现lo接口排除${NC}"
    fi
else
    echo -e "    ${YELLOW}⚠️  未发现NFQUEUE规则${NC}"
fi

echo ""

# ========================================
# 3. 验证白名单配置
# ========================================
echo -e "${GREEN}[3/3]${NC} 验证白名单配置..."

# 检查配置文件
if [ -f "config/whitelist.env" ]; then
    echo -e "  ${GREEN}✅${NC} 配置文件存在: config/whitelist.env"

    # 提取并显示配置
    IPS=$(grep "^WHITELIST_IPS=" config/whitelist.env | cut -d'=' -f2 | tr -d '"')
    CIDRS=$(grep "^WHITELIST_CIDRS=" config/whitelist.env | cut -d'=' -f2 | tr -d '"')
    DOMAINS=$(grep "^WHITELIST_DOMAINS=" config/whitelist.env | cut -d'=' -f2 | tr -d '"')

    if [ -n "$IPS" ]; then
        echo "    IP地址: $IPS"
    fi
    if [ -n "$CIDRS" ]; then
        echo "    CIDR网段: $CIDRS"
    fi
    if [ -n "$DOMAINS" ]; then
        echo "    域名白名单: $DOMAINS"
    fi

    # 安全性检查
    if grep -q "0.0.0.0/0" config/whitelist.env; then
        echo -e "    ${RED}❌ 危险配置：包含 0.0.0.0/0（允许所有IP）${NC}"
    fi

    # 检查文件权限
    PERMS=$(stat -c "%a" config/whitelist.env 2>/dev/null || stat -f "%A" config/whitelist.env 2>/dev/null)
    if [ "$PERMS" != "600" ] && [ "$PERMS" != "400" ]; then
        echo -e "    ${YELLOW}⚠️  文件权限不安全: $PERMS (建议 600)${NC}"
    fi
else
    echo -e "  ${YELLOW}⚠️  配置文件不存在，使用默认配置（仅本地回环）${NC}"
fi

echo ""

# ========================================
# 最终总结
# ========================================
echo "======================================"
echo -e "${GREEN}✅ 验证完成${NC}"
echo ""
echo "📊 系统状态:"
echo ""
echo "基础设施:"

# Anvil状态
if pgrep -x anvil > /dev/null; then
    ANvil_STATUS="运行中"
else
    ANvil_STATUS="未运行"
fi
echo "  - Anvil: $ANvil_STATUS"

# BIND9状态（综合检测）
if systemctl is-active --quiet bind9 2>/dev/null || pgrep -x named > /dev/null 2>&1 || pgrep -f "named.*-c.*bind9" > /dev/null 2>&1; then
    BIND9_STATUS="运行中"
else
    BIND9_STATUS="未运行"
fi
echo "  - BIND9: $BIND9_STATUS"

# tc/netem状态
if sudo tc qdisc show dev lo 2>/dev/null | grep -q 'netem'; then
    NETEM_STATUS="已配置"
else
    NETEM_STATUS="未配置"
fi
echo "  - tc/netem: $NETEM_STATUS"
echo ""
echo "NFQUEUE规则:"
if sudo iptables -L OUTPUT -n 2>/dev/null | grep -q "NFQUEUE"; then
    echo "  - 已配置"

    # 检测方案类型
    OUTPUT_RULES=$(sudo iptables -L OUTPUT -n 2>/dev/null | grep -E "(ACCEPT|NFQUEUE)")
    if echo "$OUTPUT_RULES" | grep -q "dpt:53.*ACCEPT" && echo "$OUTPUT_RULES" | grep -q "dpt:8545.*ACCEPT"; then
        echo "  - 方案: 端口白名单"
        echo "  - 本地服务: ✅ DNS(53)和RPC(8545)已白名单"
    elif echo "$OUTPUT_RULES" | grep -q "ACCEPT.*lo"; then
        echo "  - 方案: lo接口排除"
        echo "  - 本地回环: ✅ 已排除"
    else
        echo "  - 方案: 未知"
        echo "  - 本地服务: ❌ 未配置"
    fi
else
    echo "  - 未配置"
fi
echo ""
echo "🚀 下一步操作:"
echo ""
echo "1. 启动认证网关:"
echo "   sudo ./target/release/auth-gateway --mode full --queue-num 0"
echo ""
echo "2. 运行实验:"
echo "   python3 scripts/analyze_pcap.py     # Exp-2"
echo "   python3 scripts/exp4_ablation.py    # Exp-4"
echo ""
echo "3. 清理环境:"
echo "   sudo ./scripts/cleanup.sh"
echo ""
echo "======================================"

exit 0
