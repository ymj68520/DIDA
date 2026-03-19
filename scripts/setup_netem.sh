#!/usr/bin/env bash
#
# tc netem 网络仿真配置脚本
#
# 功能：
# 1. 为DNS查询注入20ms延迟（正态分布，5ms抖动）
# 2. 为RPC查询注入50ms延迟（正态分布，10ms抖动，0.1%丢包）
# 3. 使用HTB+fwmark实现精细化流量分类
#
# 注意：必须在 iptables NFQUEUE 规则之前执行！
#
# 使用方法：
#   sudo bash scripts/setup_netem.sh
#
# 清理方法：
#   sudo bash scripts/teardown_netem.sh

set -e

# 配置参数
DEV=${DEV:-lo}                    # 网络设备（环回用于本地测试）
DNS_DELAY=${DNS_DELAY:-20ms}      # DNS延迟均值
DNS_JITTER=${DNS_JITTER:-5ms}     # DNS抖动
RPC_DELAY=${RPC_DELAY:-50ms}      # RPC延迟均值
RPC_JITTER=${RPC_JITTER:-10ms}    # RPC抖动
RPC_LOSS=${RPC_LOSS:-0.1%}        # RPC丢包率

DNS_PORT=53                       # DNS端口
RPC_PORT=8545                     # RPC端口（Anvil默认）

echo "🔧 网络仿真配置脚本"
echo "   设备: $DEV"
echo "   DNS延迟: $DNS_DELAY ± $DNS_JITTER"
echo "   RPC延迟: $RPC_DELAY ± $RPC_JITTER (丢包 $RPC_LOSS)"
echo ""

# ── Step 1: 清除现有规则 ───────────────────────────────────
echo "[1/6] 清除 $DEV 上已有的 qdisc 规则..."
sudo tc qdisc del dev $DEV root 2>/dev/null || true
sudo tc qdisc del dev $DEV ingress 2>/dev/null || true

# ── Step 2: 挂载HTB根qdisc ───────────────────────────────────
echo "[2/6] 在 $DEV 上挂载 HTB 根 qdisc..."
sudo tc qdisc add dev $DEV root handle 1: htb default 30

# 创建根类
sudo tc class add dev $DEV parent 1: classid 1:1 htb rate 1gbit

# 创建三个子类：
# - 1:10: DNS通道（20ms延迟）
# - 1:20: RPC通道（50ms延迟+丢包）
# - 1:30: 其他流量（无延迟，默认）
sudo tc class add dev $DEV parent 1:1 classid 1:10 htb rate 1gbit prio 1
sudo tc class add dev $DEV parent 1:1 classid 1:20 htb rate 1gbit prio 2
sudo tc class add dev $DEV parent 1:1 classid 1:30 htb rate 1gbit prio 3

# ── Step 3: 挂载netem延迟规则 ─────────────────────────────────
echo "[3/6] 挂载 netem 延迟规则..."

# DNS通道：正态分布延迟
sudo tc qdisc add dev $DEV parent 1:10 handle 10: \
    netem delay $DNS_DELAY $DNS_JITTER distribution normal

# RPC通道：正态分布延迟+丢包
sudo tc qdisc add dev $DEV parent 1:20 handle 20: \
    netem delay $RPC_DELAY $RPC_JITTER distribution normal loss $RPC_LOSS

# ── Step 4: 清理旧的iptables mangle规则 ───────────────────────
echo "[4/6] 清理旧的iptables mangle规则..."
sudo iptables -t mangle -D OUTPUT -p udp --dport $DNS_PORT  -j MARK --set-mark 1 2>/dev/null || true
sudo iptables -t mangle -D OUTPUT -p tcp --dport $DNS_PORT  -j MARK --set-mark 1 2>/dev/null || true
sudo iptables -t mangle -D OUTPUT -p tcp --dport $RPC_PORT -j MARK --set-mark 2 2>/dev/null || true

# ── Step 5: 通过fwmark将流量分类 ───────────────────────────────
echo "[5/6] 配置 iptables mangle 标记..."

# 给DNS包（目标端口53）打fwmark=1
sudo iptables -t mangle -A OUTPUT -p udp --dport $DNS_PORT  -j MARK --set-mark 1
sudo iptables -t mangle -A OUTPUT -p tcp --dport $DNS_PORT  -j MARK --set-mark 1

# 给RPC包（目标端口8545）打fwmark=2
sudo iptables -t mangle -A OUTPUT -p tcp --dport $RPC_PORT -j MARK --set-mark 2

# tc filter按fwmark分流
sudo tc filter add dev $DEV parent 1: protocol ip handle 1 fw flowid 1:10
sudo tc filter add dev $DEV parent 1: protocol ip handle 2 fw flowid 1:20

# ── Step 6: 验证配置 ───────────────────────────────────────
echo ""
echo "[6/6] 验证配置..."
echo ""
echo "=== tc qdisc 配置 ==="
sudo tc qdisc show dev $DEV
echo ""
echo "=== tc filter 配置 ==="
sudo tc filter show dev $DEV
echo ""
echo "=== iptables mangle 规则 ==="
sudo iptables -t mangle -L OUTPUT -n -v

# ── 基准测试（可选）──────────────────────────────────────────
echo ""
echo "✅ netem 规则配置完成"
echo ""
echo "📊 建议执行基准测试验证延迟："
echo ""
echo "   DNS延迟测试："
echo "   dig @127.0.0.2 -p 53 example.com | grep 'Query time'"
echo ""
echo "   RPC延迟测试："
echo "   curl -o /dev/null -s -w 'Connect: %{time_connect}s\\nTotal: %{time_total}s\\n' \\"
echo "     -X POST -H 'Content-Type: application/json' \\"
echo "     -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}' \\"
echo "     http://127.0.0.1:8545"
echo ""
echo "   清理规则："
echo "   sudo bash scripts/teardown_netem.sh"
