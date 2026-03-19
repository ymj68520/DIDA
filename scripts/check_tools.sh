#!/bin/bash
#
# 快速工具检查脚本
# 验证所有工具是否在正确位置

echo "🔍 检查工具安装位置"
echo "======================================"

# 获取用户信息
ORIGINAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$ORIGINAL_USER")

echo "原始用户: $ORIGINAL_USER"
echo "用户HOME: $USER_HOME"
echo ""

# 检查Rust工具
echo "Rust工具:"
if [ -f "$USER_HOME/.cargo/bin/rustc" ]; then
    echo "  ✅ rustc: $USER_HOME/.cargo/bin/rustc"
else
    echo "  ❌ rustc: 未找到"
fi

if [ -f "$USER_HOME/.cargo/bin/cargo" ]; then
    echo "  ✅ cargo: $USER_HOME/.cargo/bin/cargo"
else
    echo "  ❌ cargo: 未找到"
fi

# 检查Foundry工具
echo ""
echo "Foundry工具:"
if [ -f "$USER_HOME/.foundry/bin/anvil" ]; then
    echo "  ✅ anvil: $USER_HOME/.foundry/bin/anvil"
else
    echo "  ❌ anvil: 未找到"
fi

if [ -f "$USER_HOME/.foundry/bin/forge" ]; then
    echo "  ✅ forge: $USER_HOME/.foundry/bin/forge"
else
    echo "  ❌ forge: 未找到"
fi

if [ -f "$USER_HOME/.foundry/bin/cast" ]; then
    echo "  ✅ cast: $USER_HOME/.foundry/bin/cast"
else
    echo "  ❌ cast: 未找到"
fi

# 检查二进制文件
echo ""
echo "二进制文件:"
if [ -f "target/release/auth-gateway" ]; then
    SIZE=$(du -h target/release/auth-gateway | cut -f1)
    echo "  ✅ auth-gateway: $SIZE"
else
    echo "  ❌ auth-gateway: 未找到"
fi

if [ -f "target/release/load_client" ]; then
    SIZE=$(du -h target/release/load_client | cut -f1)
    echo "  ✅ load_client: $SIZE"
else
    echo "  ❌ load_client: 未找到"
fi

# 检查配置文件
echo ""
echo "配置文件:"
CONFIG_OK=0
[ -f "config/contract.env" ] && echo "  ✅ contract.env" && ((CONFIG_OK++))
[ -f "config/cert_manifest.json" ] && echo "  ✅ cert_manifest.json" && ((CONFIG_OK++))
[ -f "config/trust_anchor.env" ] && echo "  ✅ trust_anchor.env" && ((CONFIG_OK++))

echo ""
echo "======================================"
if [ $CONFIG_OK -eq 3 ]; then
    echo "✅ 所有必要文件已就绪"
    echo ""
    echo "请运行:"
    echo "  sudo ./scripts/setup_all_v2.sh"
else
    echo "❌ 缺少 $CONFIG_OK 个配置文件"
fi
