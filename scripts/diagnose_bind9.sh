#!/bin/bash
#
# BIND9连接问题深度诊断和修复脚本
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "🔍 BIND9深度诊断和修复"
echo "======================================"
echo ""

# ========================================
# 步骤1：检查BIND9服务状态
# ========================================
echo -e "${YELLOW}[1/8] 检查BIND9服务状态...${NC}"
echo ""

if systemctl is-active --quiet bind9; then
    echo -e "  ${GREEN}✅ BIND9服务运行中${NC}"
else
    echo -e "  ${RED}❌ BIND9服务未运行${NC}"
    echo ""
    echo "  尝试启动BIND9..."
    sudo systemctl start bind9
    sleep 2
fi

# 检查服务详细状态
echo ""
echo "  服务详情："
sudo systemctl status bind9 --no-pager -l | head -15

echo ""
echo ""

# ========================================
# 步骤2：检查配置文件语法
# ========================================
echo -e "${YELLOW}[2/8] 检查配置文件语法...${NC}"
echo ""

echo "  主配置文件："
if sudo named-checkconf > /dev/null 2>&1; then
    echo -e "    ${GREEN}✅ named.conf 语法正确${NC}"
else
    echo -e "    ${RED}❌ named.conf 语法错误${NC}"
    sudo named-checkconf
    exit 1
fi

echo ""
echo "  区域文件检查："
if [ -f "/etc/bind/zones/rdns.zone" ]; then
    if sudo named-checkzone 1.168.192.in-addr.arpa /etc/bind/zones/rdns.zone > /dev/null 2>&1; then
        echo -e "    ${GREEN}✅ rdns.zone 配置正确${NC}"
    else
        echo -e "    ${RED}❌ rdns.zone 配置错误${NC}"
        sudo named-checkzone 1.168.192.in-addr.arpa /etc/bind/zones/rdns.zone
        exit 1
    fi
else
    echo -e "    ${RED}❌ 区域文件不存在: /etc/bind/zones/rdns.zone${NC}"
fi

echo ""

# ========================================
# 步骤3：检查监听地址配置
# ========================================
echo -e "${YELLOW}[3/8] 检查监听地址配置...${NC}"
echo ""

echo "  当前named.conf.options配置："
sudo grep -A 10 "listen-on" /etc/bind/named.conf.options 2>/dev/null || echo "    未找到listen-on配置"
echo ""

# 检查是否配置了127.0.0.2
if sudo grep -q "127.0.0.2" /etc/bind/named.conf.options 2>/dev/null; then
    echo -e "    ${GREEN}✅ 已配置127.0.0.2监听${NC}"
else
    echo -e "    ${YELLOW}⚠️  未配置127.0.0.2监听${NC}"
fi

echo ""

# ========================================
# 步骤4：检查实际监听的端口
# ========================================
echo -e "${YELLOW}[4/8] 检查实际监听的端口...${NC}"
echo ""

echo "  BIND9监听端口："
sudo netstat -tulpn | grep named | grep :53 || echo "  ⚠️  未找到named进程监听53端口"
echo ""

echo "  所有监听53端口的进程："
sudo netstat -tulpn | grep :53 || echo "  ⚠️  未找到任何进程监听53端口"
echo ""

# ========================================
# 步骤5：检查BIND9错误日志
# ========================================
echo -e "${YELLOW}[5/8] 检查BIND9错误日志...${NC}"
echo ""

if [ -f "/var/log/syslog" ]; then
    echo "  最近的BIND9错误："
    sudo grep -i "named\|bind" /var/log/syslog | tail -20 | grep -i "error\|fail\|refused" || echo "    未发现错误"
else
    echo "    日志文件不存在"
fi

echo ""

# ========================================
# 步骤6：检查端口冲突
# ========================================
echo -e "${YELLOW}[6/8] 检查端口冲突...${NC}"
echo ""

echo "  检查systemd-resolved是否占用53端口："
if sudo systemctl is-active --quiet systemd-resolved; then
    echo -e "    ${YELLOW}⚠️  systemd-resolved正在运行${NC}"
    echo "    这可能占用53端口导致BIND9无法启动"

    echo ""
    echo "    systemd-resolved监听状态："
    sudo netstat -tulpn | grep systemd-resolved | grep :53 || echo "    未占用53端口"
else
    echo -e "    ${GREEN}✅ systemd-resolved未运行${NC}"
fi

echo ""

# ========================================
# 步骤7：测试DNS查询
# ========================================
echo -e "${YELLOW}[7/8] 测试DNS查询...${NC}"
echo ""

echo "  测试127.0.0.1:53（默认）："
if dig @127.0.0.1 -p 53 example.com +short +time=2 > /dev/null 2>&1; then
    echo -e "    ${GREEN}✅ 127.0.0.1:53 可用${NC}"
else
    echo -e "    ${RED}❌ 127.0.0.1:53 不可用${NC}"
fi

echo ""
echo "  测试127.0.0.2:53（配置地址）："
if dig @127.0.0.2 -p 53 example.com +short +time=2 > /dev/null 2>&1; then
    echo -e "    ${GREEN}✅ 127.0.0.2:53 可用${NC}"
else
    echo -e "    ${RED}❌ 127.0.0.2:53 不可用${NC}"
fi

echo ""
echo "  测试本地DNS查询："
if dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short +time=2 > /dev/null 2>&1; then
    echo -e "    ${GREEN}✅ rDNS查询成功${NC}"
    RESULT=$(dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short)
    echo "    查询结果: $RESULT"
else
    echo -e "    ${RED}❌ rDNS查询失败${NC}"
    echo "    详细错误："
    dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +time=2 2>&1 | head -5
fi

echo ""

# ========================================
# 步骤8：修复建议和自动修复
# ========================================
echo -e "${YELLOW}[8/8] 诊断结论和修复...${NC}"
echo ""

# 检查主要问题
LISTEN_ON_127_0_2=false
BIND9_LISTENING=false

if sudo grep -q "127.0.0.2" /etc/bind/named.conf.options 2>/dev/null; then
    LISTEN_ON_127_0_2=true
fi

if sudo netstat -tulpn 2>/dev/null | grep -q "named.*127.0.0.2.*53"; then
    BIND9_LISTENING=true
fi

echo "  诊断结果："
echo "  - 配置127.0.0.2: $LISTEN_ON_127_0_2"
echo "  - 实际监听127.0.0.2: $BIND9_LISTENING"
echo ""

if [ "$LISTEN_ON_127_0_2" = false ]; then
    echo -e "  ${RED}❌ 问题：配置文件未设置监听127.0.0.2${NC}"
    echo ""
    echo "  🔧 开始修复..."

    # 备份配置文件
    sudo cp /etc/bind/named.conf.options /etc/bind/named.conf.options.backup.$(date +%Y%m%d%H%M%S)

    # 修改配置文件
    echo ""
    echo "  更新named.conf.options配置..."

    # 检查是否已经有listen-on配置
    if sudo grep -q "listen-on" /etc/bind/named.conf.options; then
        # 更新现有配置
        sudo sed -i 's/listen-on { .* };/listen-on { 127.0.0.1; 127.0.0.2; };/g' /etc/bind/named.conf.options
    else
        # 添加新配置
        sudo sed -i '/options {/a \    listen-on { 127.0.0.1; 127.0.0.2; };' /etc/bind/named.conf.options
    fi

    echo -e "    ${GREEN}✅ 配置已更新${NC}"

    # 重启BIND9
    echo ""
    echo "  重启BIND9服务..."
    sudo systemctl restart bind9
    sleep 3

    # 验证修复
    echo ""
    if dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short +time=2 > /dev/null 2>&1; then
        echo -e "  ${GREEN}✅ 修复成功！127.0.0.2:53现在可用${NC}"
    else
        echo -e "  ${RED}❌ 修复失败，需要手动检查${NC}"
    fi

elif [ "$BIND9_LISTENING" = false ]; then
    echo -e "  ${RED}❌ 问题：BIND9未在127.0.0.2:53上监听${NC}"
    echo ""
    echo "  可能原因："
    echo "  1. systemd-resolved占用了53端口"
    echo "  2. BIND9配置错误"
    echo "  3. BIND9启动失败"
    echo ""
    echo "  🔧 尝试修复..."

    # 停止systemd-resolved
    if sudo systemctl is-active --quiet systemd-resolved; then
        echo "  停止systemd-resolved..."
        sudo systemctl stop systemd-resolved
        sleep 1

        # 重启BIND9
        echo "  重启BIND9..."
        sudo systemctl restart bind9
        sleep 3

        # 验证
        if dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short +time=2 > /dev/null 2>&1; then
            echo -e "  ${GREEN}✅ 修复成功！127.0.0.2:53现在可用${NC}"
        else
            echo -e "  ${RED}❌ 修复失败，需要手动检查${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠️  systemd-resolved未运行，可能是其他问题${NC}"
    fi
else
    echo -e "  ${GREEN}✅ BIND9配置正确且正在监听${NC}"
fi

echo ""
echo "======================================"
echo -e "${GREEN}✅ 诊断完成${NC}"
echo ""

# 最终验证
echo "📊 最终验证："
echo ""

if dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short +time=2 > /dev/null 2>&1; then
    echo -e "  ${GREEN}✅ rDNS查询测试通过${NC}"
    RESULT=$(dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short)
    echo "  查询结果: $RESULT"
else
    echo -e "  ${RED}❌ rDNS查询测试失败${NC}"
    echo ""
    echo "  手动排查步骤："
    echo "  1. 检查配置文件: sudo cat /etc/bind/named.conf.options"
    echo "  2. 检查监听端口: sudo netstat -tulpn | grep :53"
    echo "  3. 检查错误日志: sudo journalctl -u bind9 -n 50"
    echo "  4. 测试默认地址: dig @127.0.0.1 -p 53 example.com"
fi

echo ""
echo "======================================"
