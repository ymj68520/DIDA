#!/bin/bash
#
# BIND9配置深度诊断脚本
#

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "🔍 BIND9配置深度诊断"
echo "======================================"
echo ""

# ========================================
# 1. 检查所有配置文件
# ========================================
echo -e "${YELLOW}[1/8] 检查所有配置文件...${NC}"
echo ""

echo "配置文件列表："
ls -la /etc/bind/named.conf* 2>/dev/null
echo ""

echo "主配置文件内容："
sudo cat /etc/bind/named.conf
echo ""

echo "named.conf.options内容："
sudo cat /etc/bind/named.conf.options
echo ""

echo "named.conf.local内容："
sudo cat /etc/bind/named.conf.local 2>/dev/null || echo "文件不存在"
echo ""

# ========================================
# 2. 检查配置冲突
# ========================================
echo -e "${YELLOW}[2/8] 检查配置冲突...${NC}"
echo ""

echo "查找所有listen-on配置："
sudo grep -r "listen-on" /etc/bind/ 2>/dev/null | grep -v "Binary file"
echo ""

echo "查找所有allow-query配置："
sudo grep -r "allow-query" /etc/bind/ 2>/dev/null | grep -v "Binary file"
echo ""

# ========================================
# 3. 验证配置语法
# ========================================
echo -e "${YELLOW}[3/8] 验证配置语法...${NC}"
echo ""

echo "主配置文件验证："
if sudo named-checkconf > /dev/null 2>&1; then
    echo -e "  ${GREEN}✅${NC} 主配置文件语法正确"
else
    echo -e "  ${RED}❌${NC} 主配置文件语法错误"
    sudo named-checkconf
fi

echo ""
echo "named.conf.options验证："
if sudo named-checkconf /etc/bind/named.conf.options > /dev/null 2>&1; then
    echo -e "  ${GREEN}✅${NC} named.conf.options语法正确"
else
    echo -e "  ${RED}❌${NC} named.conf.options语法错误"
    sudo named-checkconf /etc/bind/named.conf.options
fi

echo ""
echo "named.conf.local验证："
if [ -f /etc/bind/named.conf.local ]; then
    if sudo named-checkconf /etc/bind/named.conf.local > /dev/null 2>&1; then
        echo -e "  ${GREEN}✅${NC} named.conf.local语法正确"
    else
        echo -e "  ${RED}❌${NC} named.conf.local语法错误"
        sudo named-checkconf /etc/bind/named.conf.local
    fi
else
    echo -e "  ${YELLOW}⚠️${NC}  named.conf.local不存在"
fi

# ========================================
# 4. 查看BIND9实际加载的配置
# ========================================
echo ""
echo -e "${YELLOW}[4/8] 查看BIND9实际加载的配置...${NC}"
echo ""

echo "BIND9版本和配置路径："
sudo named -V
echo ""

echo "解析后的配置（前50行）："
sudo named-checkconf -p 2>/dev/null | head -50

# ========================================
# 5. 检查监听端口
# ========================================
echo ""
echo -e "${YELLOW}[5/8] 检查监听端口...${NC}"
echo ""

echo "IPv4监听端口："
sudo netstat -tulpn | grep named | grep "tcp.*127.0.0" | awk '{print $4}' | sort -u
echo ""

echo "IPv6监听端口："
sudo netstat -tulpn | grep named | grep "tcp6.*::1" | awk '{print $4}' | sort -u
echo ""

# ========================================
# 6. 查看BIND9启动日志
# ========================================
echo -e "${YELLOW}[6/8] 查看BIND9启动日志...${NC}"
echo ""

echo "最近5分钟的BIND9日志："
sudo journalctl -u bind9 --since "5 minutes ago" --no-pager | tail -30
echo ""

echo "系统日志中的BIND9错误："
sudo grep -i "named" /var/log/syslog 2>/dev/null | tail -20 || echo "无法读取系统日志"
echo ""

# ========================================
# 7. 测试DNS查询
# ========================================
echo -e "${YELLOW}[7/8] 测试DNS查询...${NC}"
echo ""

echo -n "127.0.0.1:53 - "
if dig @127.0.0.1 -p 53 100.1.168.192.in-addr.arpa TXT +short +time=2 > /dev/null 2>&1; then
    echo -e "${GREEN}✅ 可用${NC}"
    RESULT=$(dig @127.0.0.1 -p 53 100.1.168.192.in-addr.arpa TXT +short)
    echo "  结果: $RESULT"
else
    echo -e "${RED}❌ 不可用${NC}"
    dig @127.0.0.1 -p 53 100.1.168.192.in-addr.arpa TXT +time=2 2>&1 | head -5
fi

echo ""
echo -n "127.0.0.2:53 - "
if dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short +time=2 > /dev/null 2>&1; then
    echo -e "${GREEN}✅ 可用${NC}"
    RESULT=$(dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short)
    echo "  结果: $RESULT"
else
    echo -e "${RED}❌ 不可用${NC}"
    dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +time=2 2>&1 | head -5
fi

# ========================================
# 8. 诊断结论和建议
# ========================================
echo ""
echo -e "${YELLOW}[8/8] 诊断结论和建议...${NC}"
echo ""

# 检查是否监听127.0.0.2
if sudo netstat -tulpn | grep -q "named.*127.0.0.2.*53"; then
    echo -e "${GREEN}✅ BIND9正在监听127.0.0.2:53${NC}"
    echo ""
    echo "配置正常，无需修复。"
else
    echo -e "${RED}❌ BIND9未监听127.0.0.2:53${NC}"
    echo ""
    echo "可能原因："
    echo "1. 配置文件没有被正确加载"
    echo "2. named.conf.local或其他配置文件覆盖了设置"
    echo "3. BIND9启动时遇到错误"
    echo ""
    echo -e "${BLUE}💡 推荐解决方案：${NC}"
    echo ""
    echo "方案1：简化配置（推荐）"
    echo "-----------------------------------"
    echo "# 创建最小化配置"
    echo "sudo tee /etc/bind/named.conf > /dev/null << 'EOF'"
    echo "include \"/etc/bind/named.conf.options\";"
    echo "include \"/etc/bind/named.conf.local\";"
    echo "EOF"
    echo ""
    echo "# 确保named.conf.options只包含："
    echo "sudo tee /etc/bind/named.conf.options > /dev/null << 'EOF'"
    echo "options {"
    echo "    directory \"/var/cache/bind\";"
    echo "    listen-on { 127.0.0.1; 127.0.0.2; };"
    echo "    listen-on-v6 { ::1; };"
    echo "    allow-query { any; };"
    echo "    recursion no;"
    echo "};"
    echo "EOF"
    echo ""
    echo "# 重启BIND9"
    echo "sudo systemctl stop bind9"
    echo "sudo systemctl start bind9"
    echo ""
    echo "方案2：监听所有接口（临时方案）"
    echo "-----------------------------------"
    echo "# 修改配置监听所有接口"
    echo "sudo sed -i 's/listen-on.*/listen-on { any; };/' /etc/bind/named.conf.options"
    echo "sudo systemctl restart bind9"
    echo ""
    echo "⚠️  注意：监听所有接口有安全风险，仅用于实验环境"
    echo ""
    echo "方案3：使用端口转发（workaround）"
    echo "-----------------------------------"
    echo "# 使用iptables转发127.0.0.2到127.0.0.1"
    echo "sudo iptables -t nat -A OUTPUT -p tcp -d 127.0.0.2 --dport 53 -j DNAT --to-destination 127.0.0.1:53"
    echo "sudo iptables -t nat -A OUTPUT -p udp -d 127.0.0.2 --dport 53 -j DNAT --to-destination 127.0.0.1:53"
fi

echo ""
echo "======================================"
echo -e "${GREEN}✅ 诊断完成${NC}"
echo ""
