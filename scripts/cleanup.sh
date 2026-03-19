#!/bin/bash
#
# DIDA系统一键清理脚本
#
# 功能：
# 1. 停止认证网关
# 2. 清除NFQUEUE规则
# 3. 清除网络仿真规则
# 4. 停止BIND9
# 5. 停止Anvil
# 6. 清理临时文件
#
# 使用方法：
#   sudo bash scripts/cleanup_all.sh

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32M'
YELLOW='\033[1;33M'
NC='\033[0M' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo "🧹 DIDA系统清理开始"
echo "======================================"

# ────────────────────────────────────────────────────────────────
# Step 1: 停止认证网关进程
# ────────────────────────────────────────────────────────────────
log_info "[1/6] 停止认证网关进程..."

if pgrep -f "auth-gateway" > /dev/null; then
    pkill -f "auth-gateway"
    log_info "已停止auth-gateway进程"
else
    log_info "未发现运行中的auth-gateway进程"
fi

# ────────────────────────────────────────────────────────────────
# Step 2: 清除NFQUEUE规则
# ────────────────────────────────────────────────────────────────
log_info "[2/6] 清除NFQUEUE规则..."

# 清除端口白名单ACCEPT规则（setup_nfq_port_whitelist.sh）
iptables -D OUTPUT -p tcp --tcp-flags SYN,RST SYN --dport 53 -j ACCEPT 2>/dev/null || true
iptables -D OUTPUT -p tcp --tcp-flags SYN,RST SYN --dport 8545 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --tcp-flags SYN,RST SYN --sport 53 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --tcp-flags SYN,RST SYN --sport 8545 -j ACCEPT 2>/dev/null || true

# 清除lo接口ACCEPT规则（setup.sh标准方案）
iptables -D OUTPUT -o lo -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i lo -j ACCEPT 2>/dev/null || true

# 清除NFQUEUE规则
iptables -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>/dev/null || true
iptables -D INPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>/dev/null || true

# 尝试清除各种可能的NFQUEUE规则格式
iptables -D OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>/dev/null || true
iptables -D INPUT ! -i lo -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>/dev/null || true

log_info "已清除所有NFQUEUE和端口白名单/lo接口规则"

# ────────────────────────────────────────────────────────────────
# Step 3: 清除网络仿真规则
# ────────────────────────────────────────────────────────────────
log_info "[3/6] 清除网络仿真规则..."

if tc qdisc show dev lo | grep -q "qdisc"; then
    tc qdisc del dev lo root 2>/dev/null || true
    log_info "已清除tc netem规则"
else
    log_info "未发现tc netem规则"
fi

# 清除iptables mangle规则
if iptables -t mangle -L OUTPUT -n | grep -q "MARK"; then
    iptables -t mangle -F OUTPUT
    log_info "已清除iptables mangle规则"
else
    log_info "未发现iptables mangle规则"
fi

# ────────────────────────────────────────────────────────────────
# Step 4: 停止BIND9
# ────────────────────────────────────────────────────────────────
log_info "[4/6] 停止BIND9..."

if systemctl is-active --quiet bind9 2>/dev/null; then
    systemctl stop bind9
    log_info "已停止BIND9服务"
else
    log_info "BIND9服务未运行"
fi

# 如果systemd-resolved被停止了，可以选择重启
# systemctl start systemd-resolved 2>/dev/null || true

# ────────────────────────────────────────────────────────────────
# Step 5: 停止Anvil
# ────────────────────────────────────────────────────────────────
log_info "[5/6] 停止Anvil..."

if pgrep -x anvil > /dev/null; then
    if [ -f logs/anvil.pid ]; then
        kill $(cat logs/anvil.pid) 2>/dev/null || true
        rm logs/anvil.pid
    fi

    # 如果进程仍在运行，强制杀死
    if pgrep -x anvil > /dev/null; then
        pkill -9 anvil
    fi

    log_info "已停止Anvil进程"
else
    log_info "Anvil进程未运行"
fi

# ────────────────────────────────────────────────────────────────
# Step 6: 清理临时文件（可选）
# ────────────────────────────────────────────────────────────────
log_info "[6/6] 清理临时文件..."

# 清理PID文件
rm -f logs/anvil.pid

# 询问是否清理日志文件
echo ""
read -p "是否清理日志文件? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f logs/*.log
    log_info "已清理日志文件"
else
    log_info "保留日志文件"
fi

# ────────────────────────────────────────────────────────────────
# 验证清理结果
# ────────────────────────────────────────────────────────────────
echo ""
echo "======================================"
echo "📊 清理验证报告"
echo "======================================"

# Anvil状态
echo -n "Anvil: "
if pgrep -x anvil > /dev/null; then
    echo -e "${RED}❌ 仍在运行${NC}"
else
    echo -e "${GREEN}✅ 已停止${NC}"
fi

# BIND9状态
echo -n "BIND9: "
if systemctl is-active --quiet bind9 2>/dev/null; then
    echo -e "${RED}❌ 仍在运行${NC}"
else
    echo -e "${GREEN}✅ 已停止${NC}"
fi

# 网络仿真状态
echo -n "网络仿真: "
if tc qdisc show dev lo | grep -q "qdisc"; then
    echo -e "${RED}❌ 规则仍在${NC}"
else
    echo -e "${GREEN}✅ 已清除${NC}"
fi

# NFQUEUE规则状态
echo -n "NFQUEUE规则: "
if iptables -L OUTPUT -n | grep -q "NFQUEUE"; then
    echo -e "${RED}❌ 规则仍在${NC}"
else
    echo -e "${GREEN}✅ 已清除${NC}"
fi

echo "======================================"

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}✅ 清理完成！${NC}"
echo -e "${GREEN}======================================${NC}"

echo ""
echo "💡 提示:"
echo "   - 如需重启systemd-resolved: sudo systemctl start systemd-resolved"
echo "   - 如需重启BIND9: sudo systemctl start bind9"
echo "   - 查看完整日志: cat scripts/cleanup_all.sh"
echo ""

exit 0
