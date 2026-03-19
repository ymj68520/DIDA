#!/bin/bash
#
# BIND9 IPv4监听修复脚本
#
# 问题：BIND9配置了listen-on但没有监听IPv4地址
# 原因：配置文件中缺少IPv4监听配置或配置格式错误

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "🔧 BIND9 IPv4监听修复"
echo "======================================"
echo ""

# 备份配置文件
BACKUP_FILE="/etc/bind/named.conf.options.backup.$(date +%Y%m%d%H%M%S)"
echo -e "${YELLOW}[1/6] 备份配置文件...${NC}"
sudo cp /etc/bind/named.conf.options "$BACKUP_FILE"
echo -e "  ${GREEN}✅ 已备份到: $BACKUP_FILE${NC}"

# 检查当前配置
echo ""
echo -e "${YELLOW}[2/6] 检查当前配置...${NC}"
echo ""
echo "当前named.conf.options内容："
sudo cat /etc/bind/named.conf.options
echo ""

# 修复配置
echo ""
echo -e "${YELLOW}[3/6] 修复配置文件...${NC}"
echo ""

# 创建新的配置文件
cat > /tmp/named.conf.options.new << 'EOF'
options {
	directory "/var/cache/bind";

	// IPv4监听配置 - 关键修复
	listen-on-v6 { any; };
	listen-on port 53 { 127.0.0.1; 127.0.0.2; };

	// 允许查询
	allow-query { any; };

	// 禁用递归（仅作为权威DNS服务器）
	recursion no;

	// DNSSEC验证
	dnssec-validation auto;
};
EOF

# 应用新配置
echo "  应用新配置..."
sudo cp /tmp/named.conf.options.new /etc/bind/named.conf.options
echo -e "  ${GREEN}✅ 配置已更新${NC}"

# 显示新配置
echo ""
echo "  新配置内容："
sudo cat /etc/bind/named.conf.options
echo ""

# 验证配置
echo ""
echo -e "${YELLOW}[4/6] 验证配置语法...${NC}"
if sudo named-checkconf > /dev/null 2>&1; then
    echo -e "  ${GREEN}✅ 配置语法正确${NC}"
else
    echo -e "  ${RED}❌ 配置语法错误${NC}"
    sudo named-checkconf
    echo ""
    echo "  恢复备份配置..."
    sudo cp "$BACKUP_FILE" /etc/bind/named.conf.options
    exit 1
fi

# 验证区域文件
echo ""
echo -e "${YELLOW}[5/6] 验证区域文件...${NC}"
if [ -f "/etc/bind/zones/rdns.zone" ]; then
    if sudo named-checkzone 1.168.192.in-addr.arpa /etc/bind/zones/rdns.zone > /dev/null 2>&1; then
        echo -e "  ${GREEN}✅ 区域文件正确${NC}"
    else
        echo -e "  ${YELLOW}⚠️  区域文件有问题${NC}"
        sudo named-checkzone 1.168.192.in-addr.arpa /etc/bind/zones/rdns.zone
    fi
fi

# 重启BIND9
echo ""
echo -e "${YELLOW}[6/6] 重启BIND9服务...${NC}"
sudo systemctl restart bind9
sleep 3

# 检查服务状态
echo ""
if systemctl is-active --quiet bind9; then
    echo -e "  ${GREEN}✅ BIND9服务运行中${NC}"
else
    echo -e "  ${RED}❌ BIND9服务启动失败${NC}"
    echo ""
    echo "  服务状态："
    sudo systemctl status bind9 --no-pager | head -20
    echo ""
    echo "  恢复备份配置..."
    sudo cp "$BACKUP_FILE" /etc/bind/named.conf.options
    sudo systemctl restart bind9
    exit 1
fi

# 验证监听端口
echo ""
echo "======================================"
echo "🔍 验证修复结果"
echo "======================================"
echo ""

echo "检查BIND9监听端口："
sudo netstat -tulpn | grep named | grep -E "127.0.0.(1|2).*53" || echo "  ⚠️  未找到IPv4监听"
echo ""

echo "检查所有named监听端口："
sudo netstat -tulpn | grep named | grep :53 | head -10
echo ""

# 测试DNS查询
echo "测试DNS查询："

echo -n "  127.0.0.1:53 - "
if dig @127.0.0.1 -p 53 example.com +short +time=2 > /dev/null 2>&1; then
    echo -e "${GREEN}✅ 可用${NC}"
else
    echo -e "${RED}❌ 不可用${NC}"
fi

echo -n "  127.0.0.2:53 - "
if dig @127.0.0.2 -p 53 example.com +short +time=2 > /dev/null 2>&1; then
    echo -e "${GREEN}✅ 可用${NC}"
else
    echo -e "${RED}❌ 不可用${NC}"
fi

echo ""
echo -n "  rDNS查询 - "
if dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short +time=2 > /dev/null 2>&1; then
    echo -e "${GREEN}✅ 成功${NC}"
    RESULT=$(dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short)
    echo "  结果: $RESULT"
else
    echo -e "${RED}❌ 失败${NC}"
fi

echo ""
echo "======================================"
echo -e "${GREEN}✅ 修复完成${NC}"
echo ""

# 最终总结
echo "📊 修复总结："
echo ""

if sudo netstat -tulpn 2>/dev/null | grep -q "named.*127.0.0.2.*53"; then
    echo -e "  ${GREEN}✅ BIND9现在正确监听127.0.0.2:53${NC}"
else
    echo -e "  ${RED}❌ BIND9仍未监听127.0.0.2:53${NC}"
    echo ""
    echo "  可能需要额外排查："
    echo "  1. 检查是否有其他进程占用53端口"
    echo "  2. 检查BIND9错误日志: sudo journalctl -u bind9 -n 50"
    echo "  3. 检查防火墙规则"
fi

echo ""
echo "配置文件位置："
echo "  - 当前配置: /etc/bind/named.conf.options"
echo "  - 备份配置: $BACKUP_FILE"
echo ""

echo "如需恢复备份配置："
echo "  sudo cp $BACKUP_FILE /etc/bind/named.conf.options"
echo "  sudo systemctl restart bind9"
echo ""

echo "======================================"
