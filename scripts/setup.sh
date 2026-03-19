#!/bin/bash
#
# DIDA系统一键设置脚本 v4.0
#
# 改进：
# - 集成BIND9 IPv4监听修复
# - 支持两种NFQUEUE配置方案（lo接口排除 + 端口白名单）
# - 自动降级：lo接口失败时自动使用端口白名单方案
# - 添加BIND9 IPv4监听验证
# - 改进错误处理和状态显示

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ────────────────────────────────────────────────────────────────
# 环境设置
# ────────────────────────────────────────────────────────────────
ORIGINAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$ORIGINAL_USER")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 添加用户bin目录到PATH
export PATH="$USER_HOME/.cargo/bin:$USER_HOME/.foundry/bin:$PATH"

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}DIDA系统一键设置 v4.0${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "${GREEN}[INFO]${NC} 项目根目录: $PROJECT_ROOT"
echo -e "${GREEN}[INFO]${NC} 原始用户: $ORIGINAL_USER"
echo -e "${GREEN}[INFO]${NC} 用户HOME: $USER_HOME"
echo -e "${GREEN}[INFO]${NC} PATH: $PATH"
echo ""

# 错误处理函数
handle_error() {
    local step_name="$1"
    local error_msg="$2"

    echo -e "${RED}❌ 错误: ${step_name}${NC}"
    echo -e "${RED}   详情: ${error_msg}${NC}"
    echo ""
    echo -e "${YELLOW}💡 建议:${NC}"
    echo "   1. 检查上述错误信息"
    echo "   2. 运行: bash scripts/check_tools.sh"
    echo "   3. 查看日志: tail -f logs/anvil.log"
    echo ""

    exit 1
}

success_step() {
    echo -e "${GREEN}  ✅${NC} $1"
}

# ────────────────────────────────────────────────────────────────
# Step 1: 检查配置文件
# ────────────────────────────────────────────────────────────────
echo -e "${GREEN}[1/6]${NC} 检查配置文件..."

CONFIG_MISSING=0
if [ ! -f "config/contract.env" ]; then
    ((CONFIG_MISSING++))
    echo -e "${RED}  ❌ config/contract.env${NC}"
fi
if [ ! -f "config/cert_manifest.json" ]; then
    ((CONFIG_MISSING++))
    echo -e "${RED}  ❌ config/cert_manifest.json${NC}"
fi
if [ ! -f "config/trust_anchor.env" ]; then
    ((CONFIG_MISSING++))
    echo -e "${RED}  ❌ config/trust_anchor.env${NC}"
fi

if [ $CONFIG_MISSING -gt 0 ]; then
    handle_error "配置文件检查" "缺少 $CONFIG_MISSING 个配置文件"
else
    success_step "所有配置文件存在"
fi

# ────────────────────────────────────────────────────────────────
# Step 2: 检查二进制文件
# ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}[2/6]${NC} 检查二进制文件..."

BINARIES_OK=0
if [ -f "target/release/auth-gateway" ]; then
    SIZE=$(du -h target/release/auth-gateway | cut -f1)
    echo -e "${GREEN}  ✅${NC} auth-gateway ($SIZE)"
    ((BINARIES_OK++))
else
    echo -e "${YELLOW}  ⚠${NC}  auth-gateway 不存在"
fi

if [ -f "target/release/load_client" ]; then
    SIZE=$(du -h target/release/load_client | cut -f1)
    echo -e "${GREEN}  ✅${NC} load_client ($SIZE)"
    ((BINARIES_OK++))
else
    echo -e "${YELLOW}  ⚠${NC}  load_client 不存在"
fi

if [ $BINARIES_OK -lt 2 ]; then
    echo -e "${YELLOW}  📦 二进制文件不完整，尝试编译...${NC}"

    # 尝试编译
    if [ -n "$SUDO_USER" ]; then
        echo -e "${YELLOW}  🔄 切换到用户 $ORIGINAL_USER 进行编译...${NC}"
        if su - "$ORIGINAL_USER" -c "cd $PROJECT_ROOT && cargo build --release 2>&1 | tail -20"; then
            success_step "编译完成"
        else
            handle_error "二进制编译" "cargo build --release 失败"
        fi
    else
        if cargo build --release 2>&1 | tail -20; then
            success_step "编译完成"
        else
            handle_error "二进制编译" "cargo build --release 失败"
        fi
    fi
else
    success_step "二进制文件检查"
fi

# ────────────────────────────────────────────────────────────────
# Step 3: 启动Anvil
# ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}[3/6]${NC} 启动Anvil区块链节点..."

if pgrep -x anvil > /dev/null; then
    echo -e "${YELLOW}  ⚠${NC}  Anvil已在运行 (PID: $(pgrep -x anvil))"
else
    # 查找anvil二进制
    ANVIL_BIN="anvil"
    if [ -f "$USER_HOME/.foundry/bin/anvil" ]; then
        ANVIL_BIN="$USER_HOME/.foundry/bin/anvil"
        echo -e "${YELLOW}  📂 使用用户安装的anvil: $ANVIL_BIN${NC}"
    fi

    echo -e "${YELLOW}  🚀 启动Anvil...${NC}"
    mkdir -p logs

    # 启动anvil并捕获输出（不设置block-time，使用默认自动挖矿）
    $ANVIL_BIN --host 127.0.0.1 --port 8545 > logs/anvil.log 2>&1 &
    ANVIL_PID=$!
    echo $ANVIL_PID > logs/anvil.pid

    echo -e "${YELLOW}  ⏳ 等待Anvil启动...${NC}"
    sleep 3

    # 检查进程
    if pgrep -x anvil > /dev/null; then
        success_step "Anvil已启动 (PID: $ANVIL_PID)"

        # 验证RPC
        echo -e "${YELLOW}  🔍 验证RPC连接...${NC}"
        if command -v curl &> /dev/null; then
            if curl -s -X POST -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                http://127.0.0.1:8545 2>/dev/null | grep -q "0x"; then
                success_step "Anvil RPC连接正常"
            else
                echo -e "${YELLOW}  ⚠${NC}  RPC验证失败（curl问题）"
            fi
        else
            echo -e "${YELLOW}  ⚠${NC}  curl不可用，跳过RPC验证"
        fi
    else
        handle_error "Anvil启动" "进程未运行，查看日志: tail -20 logs/anvil.log"
    fi
fi

# ────────────────────────────────────────────────────────────────
# Step 4: 安装和配置BIND9
# ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}[4/6]${NC} 安装和配置BIND9..."

# 检查BIND9是否安装
if ! command -v named &> /dev/null; then
    echo -e "${YELLOW}  📦 BIND9未安装，开始安装...${NC}"
    if apt-get update -qq 2>&1; then
        echo -e "${GREEN}  ✅${NC} apt-get update成功"
    else
        handle_error "BIND9安装" "apt-get update 失败"
    fi

    if apt-get install -y bind9 bind9-utils dnsutils 2>&1; then
        success_step "BIND9安装完成"
    else
        handle_error "BIND9安装" "apt-get install 失败"
    fi
else
    echo -e "${YELLOW}  ⚠${NC}  BIND9已安装"
fi

# 生成zone文件
if [ -f "scripts/gen_zone.py" ]; then
    echo -e "${YELLOW}  📝 生成BIND9 zone文件...${NC}"
    if python3 scripts/gen_zone.py 2>&1; then
        success_step "Zone文件已生成"
    else
        echo -e "${YELLOW}  ⚠️${NC}  Zone文件生成失败（可能非致命）"
    fi
fi

# 配置BIND9
echo -e "${YELLOW}  🔧 配置BIND9...${NC}"
mkdir -p /etc/bind/zones

if cp config/rdns.zone /etc/bind/zones/ 2>/dev/null; then
    echo -e "${GREEN}  ✅${NC} Zone文件已复制"
else
    echo -e "${RED}  ❌${NC} Zone文件复制失败"
fi

if cp config/named.conf.local /etc/bind/named.conf.local 2>/dev/null; then
    echo -e "${GREEN}  ✅${NC} named.conf.local已复制"
else
    echo -e "${RED}  ❌${NC} named.conf.local复制失败"
fi

chown bind:bind /etc/bind/zones/rdns.zone 2>/dev/null || true

# 🔧 IPv4监听修复 - 创建完整的named.conf.options
echo -e "${YELLOW}  🔧 配置IPv4监听...${NC}"

# 备份现有配置
if [ -f /etc/bind/named.conf.options ]; then
    cp /etc/bind/named.conf.options /etc/bind/named.conf.options.backup.$(date +%Y%m%d%H%M%S)
    echo -e "${GREEN}  ✅${NC} 已备份现有配置"
fi

# 创建完整的named.conf.options配置（修复IPv4监听问题）
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

if cp /tmp/named.conf.options.new /etc/bind/named.conf.options; then
    echo -e "${GREEN}  ✅${NC} named.conf.options已配置（IPv4监听已启用）"
else
    echo -e "${RED}  ❌${NC} named.conf.options配置失败"
fi

# 验证配置
if named-checkconf > /dev/null 2>&1; then
    echo -e "${GREEN}  ✅${NC} BIND9配置语法正确"
else
    echo -e "${RED}  ❌${NC} BIND9配置语法错误"
    named-checkconf
fi

# 停止systemd-resolved
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl stop systemd-resolved 2>/dev/null || true
    echo -e "${GREEN}  ✅${NC} 已停止systemd-resolved"
fi

# 启动BIND9
if systemctl is-active --quiet bind9 2>/dev/null; then
    if systemctl restart bind9 2>&1; then
        success_step "BIND9重启成功"
    else
        echo -e "${YELLOW}  ⚠️${NC}  BIND9重启失败，尝试启动..."
        if systemctl start bind9 2>&1; then
            success_step "BIND9启动成功"
        else
            echo -e "${YELLOW}  ⚠️${NC}  BIND9启动失败"
        fi
    fi
else
    if systemctl start bind9 2>&1; then
        success_step "BIND9启动成功"
    else
        echo -e "${YELLOW}  ⚠️${NC}  BIND9启动失败"
    fi
fi

# 验证IPv4监听
echo -e "${YELLOW}  🔍 验证IPv4监听...${NC}"
sleep 2

if command -v dig &> /dev/null; then
    # 测试127.0.0.1:53
    if dig @127.0.0.1 -p 53 example.com +short +time=2 > /dev/null 2>&1; then
        echo -e "${GREEN}  ✅${NC} 127.0.0.1:53 可用"
    else
        echo -e "${YELLOW}  ⚠️${NC}  127.0.0.1:53 不可用"
    fi

    # 测试127.0.0.2:53
    if dig @127.0.0.2 -p 53 example.com +short +time=2 > /dev/null 2>&1; then
        echo -e "${GREEN}  ✅${NC} 127.0.0.2:53 可用"
    else
        echo -e "${YELLOW}  ⚠️${NC}  127.0.0.2:53 不可用（可能需要运行 fix_bind9_ipv4.sh）"
    fi
else
    echo -e "${YELLOW}  ⚠️${NC}  dig不可用，跳过DNS查询验证"
fi

# ────────────────────────────────────────────────────────────────
# Step 5: 配置网络仿真
# ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}[5/6]${NC} 配置网络仿真(tc/netem)..."

echo -e "${YELLOW}  🧹 清除现有规则...${NC}"
tc qdisc del dev lo root 2>/dev/null || true
iptables -t mangle -F OUTPUT 2>/dev/null || true

echo -e "${YELLOW}  🔧 配置HTB...${NC}"
if tc qdisc add dev lo root handle 1: htb default 30 2>&1; then
    echo -e "${GREEN}  ✅${NC} HTB根qdisc已添加"
else
    echo -e "${RED}  ❌${NC} HTB配置失败"
fi

if tc class add dev lo parent 1: classid 1:1 htb rate 1gbit 2>&1; then
    echo -e "${GREEN}  ✅${NC} HTB根类已添加"
fi

if tc class add dev lo parent 1:1 classid 1:10 htb rate 1gbit 2>&1; then
    echo -e "${GREEN}  ✅${NC} DNS通道类已添加"
fi

if tc class add dev lo parent 1:1 classid 1:20 htb rate 1gbit 2>&1; then
    echo -e "${GREEN}  ✅${NC} RPC通道类已添加"
fi

echo -e "${YELLOW}  🔧 配置netem延迟...${NC}"
if tc qdisc add dev lo parent 1:10 handle 10: netem delay 20ms 5ms distribution normal 2>&1; then
    success_step "DNS通道延迟已配置 (20ms ± 5ms)"
else
    echo -e "${RED}  ❌${NC} DNS通道netem配置失败"
fi

if tc qdisc add dev lo parent 1:20 handle 20: netem delay 50ms 10ms distribution normal loss 0.1% 2>&1; then
    success_step "RPC通道延迟已配置 (50ms ± 10ms, 0.1% 丢包)"
else
    echo -e "${RED}  ❌${NC} RPC通道netem配置失败"
fi

echo -e "${YELLOW}  🔧 配置流量分类...${NC}"
iptables -t mangle -A OUTPUT -p udp --dport 53 -j MARK --set-mark 1 2>/dev/null || true
iptables -t mangle -A OUTPUT -p tcp --dport 53 -j MARK --set-mark 1 2>/dev/null || true
iptables -t mangle -A OUTPUT -p tcp --dport 8545 -j MARK --set-mark 2 2>/dev/null || true

tc filter add dev lo parent 1: handle 1 fw flowid 1:10 2>/dev/null || true
tc filter add dev lo parent 1: handle 2 fw flowid 1:20 2>/dev/null || true
success_step "流量分类已配置"

# ────────────────────────────────────────────────────────────────
# Step 6: 配置NFQUEUE规则（支持两种方案）
# ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}[6/6]${NC} 配置NFQUEUE规则..."

echo -e "${YELLOW}  🧹 清除现有NFQUEUE规则...${NC}"
# 清除端口白名单规则（如果存在）
iptables -D OUTPUT -p tcp --tcp-flags SYN,RST SYN --dport 53 -j ACCEPT 2>/dev/null || true
iptables -D OUTPUT -p tcp --tcp-flags SYN,RST SYN --dport 8545 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --tcp-flags SYN,RST SYN --sport 53 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --tcp-flags SYN,RST SYN --sport 8545 -j ACCEPT 2>/dev/null || true
# 清除lo接口规则（如果存在）
iptables -D OUTPUT -o lo -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i lo -j ACCEPT 2>/dev/null || true
# 清除NFQUEUE规则
iptables -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>/dev/null || true
iptables -D INPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>/dev/null || true

echo -e "${YELLOW}  🔧 尝试方案1：lo接口排除...${NC}"

# 尝试配置lo接口排除（标准方案）
LO_INTERFACE_OK=true

# OUTPUT链：在开头插入lo接口规则
if ! iptables -I OUTPUT 1 -o lo -j ACCEPT 2>&1; then
    echo -e "${RED}  ❌${NC} OUTPUT lo接口规则配置失败"
    LO_INTERFACE_OK=false
fi

# INPUT链：在开头插入lo接口规则
if ! iptables -I INPUT 1 -i lo -j ACCEPT 2>&1; then
    echo -e "${RED}  ❌${NC} INPUT lo接口规则配置失败"
    LO_INTERFACE_OK=false
fi

if [ "$LO_INTERFACE_OK" = true ]; then
    echo -e "${GREEN}  ✅${NC} lo接口排除规则已添加"

    # 添加NFQUEUE规则（会匹配到非lo流量）
    echo -e "${YELLOW}  🔧 添加NFQUEUE规则...${NC}"

    if iptables -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>&1; then
        echo -e "${GREEN}  ✅${NC} OUTPUT NFQUEUE规则已添加"
    fi

    if iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>&1; then
        echo -e "${GREEN}  ✅${NC} INPUT NFQUEUE规则已添加"
    fi

    success_step "NFQUEUE规则已配置（方案：lo接口排除）"

    echo ""
    echo -e "${YELLOW}  📝 说明:${NC}"
    echo -e "     - 方案：lo接口排除${NC}"
    echo -e "     - 白名单过滤在auth-gateway内部进行${NC}"
    echo -e "     - 启动auth-gateway: sudo ./target/release/auth-gateway --mode full --queue-num 0"
else
    echo -e "${YELLOW}  ⚠️  lo接口排除失败，使用方案2：端口白名单...${NC}"

    # 方案2：端口白名单
    echo -e "${YELLOW}  🔧 配置端口白名单...${NC}"

    # OUTPUT链：DNS和RPC端口直接ACCEPT
    if iptables -A OUTPUT -p tcp --tcp-flags SYN,RST SYN --dport 53 -j ACCEPT 2>&1; then
        echo -e "${GREEN}  ✅${NC} DNS端口（53）已白名单"
    fi

    if iptables -A OUTPUT -p tcp --tcp-flags SYN,RST SYN --dport 8545 -j ACCEPT 2>&1; then
        echo -e "${GREEN}  ✅${NC} RPC端口（8545）已白名单"
    fi

    # 其他端口进入NFQUEUE
    if iptables -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>&1; then
        echo -e "${GREEN}  ✅${NC} OUTPUT NFQUEUE规则已添加"
    fi

    # INPUT链：DNS和RPC端口直接ACCEPT
    if iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN --sport 53 -j ACCEPT 2>&1; then
        echo -e "${GREEN}  ✅${NC} DNS端口（53）已白名单"
    fi

    if iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN --sport 8545 -j ACCEPT 2>&1; then
        echo -e "${GREEN}  ✅${NC} RPC端口（8545）已白名单"
    fi

    # 其他端口进入NFQUEUE
    if iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN -j NFQUEUE --queue-num 0 2>&1; then
        echo -e "${GREEN}  ✅${NC} INPUT NFQUEUE规则已添加"
    fi

    success_step "NFQUEUE规则已配置（方案：端口白名单）"

    echo ""
    echo -e "${YELLOW}  📝 说明:${NC}"
    echo -e "     - 方案：端口白名单${NC}"
    echo -e "     - DNS流量（端口53）和RPC流量（端口8545）直接通过${NC}"
    echo -e "     - 其他流量进入NFQUEUE，由auth-gateway验证${NC}"
    echo -e "     - 启动auth-gateway: sudo ./target/release/auth-gateway --mode full --queue-num 0"
fi

# ────────────────────────────────────────────────────────────────
# 最终状态报告
# ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}✅ DIDA系统设置完成！${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "📊 系统状态:"

# Anvil状态
echo -n "  Anvil: "
if pgrep -x anvil > /dev/null; then
    echo -e "${GREEN}✅ 运行中${NC} (PID: $(pgrep -x anvil))"
else
    echo -e "${RED}❌ 未运行${NC}"
fi

# BIND9状态
echo -n "  BIND9: "
if systemctl is-active --quiet bind9 2>/dev/null; then
    echo -e "${GREEN}✅ 运行中${NC}"
else
    echo -e "${YELLOW}⚠️  状态未知${NC}"
fi

# 网络仿真状态
echo -n "  网络仿真: "
if tc qdisc show dev lo 2>/dev/null | grep -q "netem"; then
    echo -e "${GREEN}✅ 已配置${NC}"
else
    echo -e "${RED}❌ 未配置${NC}"
fi

echo ""
echo "🚀 下一步操作:"
echo ""
echo "1. 验证系统状态:"
echo "   sudo ./scripts/verify.sh"
echo ""
echo "2. 启动认证网关:"
echo "   sudo ./target/release/auth-gateway --mode full --queue-num 0"
echo ""
echo "3. 运行实验 (另一个终端):"
echo "   python3 scripts/analyze_pcap.py     # Exp-2"
echo "   python3 scripts/exp4_ablation.py    # Exp-4"
echo "   cargo run --release --bin load_client -- --target 192.168.1.100:80 --concurrency 100 --duration 30"
echo ""
echo "4. 生成图表:"
echo "   python3 scripts/plot_all.py"
echo ""
echo "⚠️  清理所有配置:"
echo "   sudo ./scripts/cleanup.sh"
echo ""
echo "📚 相关文档:"
echo "   scripts/README.md - 脚本使用指南"
echo "   scripts/BIND9_IPV4_FIX_REPORT.md - BIND9修复说明"
echo ""
echo "🔧 故障排除:"
echo "   - 如果BIND9连接失败: sudo ./scripts/fix_bind9_ipv4.sh"
echo "   - 如果NFQUEUE规则问题: sudo ./scripts/setup_nfq_port_whitelist.sh"
echo ""

exit 0
