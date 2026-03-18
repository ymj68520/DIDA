# DIDA (Dual-Identity DNS-Anchored Authentication) - Makefile
# 基于rDNS与联盟链的轻量级双重身份认证系统

.PHONY: help setup verify-infra clean
.PHONY: start-anvil deploy-contract provision-certs
.PHONY: start-bind9 stop-bind9
.PHONY: setup-netem teardown-netem setup-nfqueue teardown-nfqueue
.PHONY: run_exp1 run_exp2 run_exp3 run_exp4 run_exp5 plot
.PHONY: build test lint

# 默认目标
help:
	@echo "DIDA 系统管理命令"
	@echo ""
	@echo "基础设置:"
	@echo "  make setup           - 初始化完整测试环境（Anvil + 合约 + BIND9 + 证书）"
	@echo "  make verify-infra    - 验证所有基础设施组件状态"
	@echo "  make clean           - 停止所有服务并清理生成文件"
	@echo ""
	@echo "开发构建:"
	@echo "  make build           - 构建Rust网关"
	@echo "  make test            - 运行所有测试"
	@echo "  make lint            - 运行clippy检查"
	@echo ""
	@echo "基础设施组件:"
	@echo "  make start-anvil     - 启动Anvil区块链节点"
	@echo "  make deploy-contract - 部署IPCertRegistry.sol合约"
	@echo "  make provision-certs - 生成并注册测试证书"
	@echo "  make start-bind9     - 启动BIND9 DNS服务器"
	@echo "  make stop-bind9      - 停止BIND9 DNS服务器"
	@echo ""
	@echo "网络配置:"
	@echo "  make setup-netem     - 配置网络仿真（tc/netem）"
	@echo "  make teardown-netem  - 清除网络仿真规则"
	@echo "  make setup-nfqueue   - 配置iptables NFQUEUE规则（需要sudo）"
	@echo "  make teardown-nfqueue - 清除NFQUEUE规则（需要sudo）"
	@echo ""
	@echo "实验执行:"
	@echo "  make run_exp1        - Exp-1: 端到端时延拆解"
	@echo "  make run_exp2        - Exp-2: DNS报文大小对比"
	@echo "  make run_exp3        - Exp-3: RPC时延vs数据规模"
	@echo "  make run_exp4        - Exp-4: 消融实验"
	@echo "  make run_exp5        - Exp-5: 高并发吞吐量"
	@echo "  make plot            - 生成所有论文图表"

# ==============================================================================
# 基础设置
# ==============================================================================

setup: verify-infra
	@echo "==> 初始化完整测试环境..."
	@$(MAKE) -s start-anvil
	@sleep 2
	@$(MAKE) -s deploy-contract
	@$(MAKE) -s provision-certs
	@$(MAKE) -s start-bind9
	@echo "==> 环境初始化完成！"
	@$(MAKE) -s verify-infra

verify-infra:
	@echo "==> 验证基础设施组件..."
	@echo "检查Rust工具链..."
	@rustc --version || (echo "❌ Rust未安装"; exit 1)
	@cargo --version || (echo "❌ Cargo未安装"; exit 1)
	@echo "检查Foundry工具链..."
	@forge --version || (echo "❌ Foundry未安装"; exit 1)
	@anvil --version || (echo "❌ Anvil未安装"; exit 1)
	@echo "检查BIND9..."
	@named -v || (echo "❌ BIND9未安装"; exit 1)
	@echo "检查Python..."
	@python3 --version || (echo "❌ Python3未安装"; exit 1)
	@echo "✅ 所有依赖已安装"

# ==============================================================================
# 开发构建
# ==============================================================================

build:
	@echo "==> 构建Rust认证网关..."
	cargo build --release
	@echo "==> 构建完成: target/release/auth-gateway"

test:
	@echo "==> 运行Rust测试..."
	cargo test

test-contracts:
	@echo "==> 运行Solidity合约测试..."
	cd contracts && forge test -vvv

lint:
	@echo "==> 运行Clippy检查..."
	cargo clippy -- -D warnings

# ==============================================================================
# 基础设施组件
# ==============================================================================

start-anvil:
	@echo "==> 启动Anvil节点..."
	@if pgrep -x "anvil" > /dev/null; then \
		echo "Anvil已在运行"; \
	else \
		anvil --block-time 0 --host 127.0.0.1 --port 8545 > logs/anvil.log 2>&1 & \
		echo $$! > logs/anvil.pid; \
		sleep 2; \
		echo "Anvil已启动 (PID: $$(cat logs/anvil.pid))"; \
	fi

deploy-contract: start-anvil
	@echo "==> 部署IPCertRegistry合约..."
	cd contracts && forge script script/Deploy.s.sol \
		--rpc-url http://127.0.0.1:8545 \
		--broadcast \
		--private-key $${SK_TOP:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
	@echo "==> 合约部署完成，地址已记录"

provision-certs:
	@echo "==> 生成并注册测试证书..."
	python3 scripts/provision_certs.py
	@echo "==> 证书生成完成"

start-bind9:
	@echo "==> 启动BIND9服务..."
	@if pgrep -x "named" > /dev/null; then \
		echo "BIND9已在运行"; \
	else \
		sudo systemctl start bind9 || sudo named -c /etc/bind/named.conf; \
		sleep 1; \
		echo "BIND9已启动"; \
	fi
	@echo "验证DNS解析..."
	@dig @127.0.0.2 -p 53 100.1.168.192.in-addr.arpa TXT +short || echo "⚠️  DNS测试解析失败（可能尚未配置zone）"

stop-bind9:
	@echo "==> 停止BIND9服务..."
	sudo systemctl stop bind9 || sudo pkill named
	@echo "BIND9已停止"

# ==============================================================================
# 网络配置
# ==============================================================================

setup-netem:
	@echo "==> 配置网络仿真（tc/netem）..."
	sudo bash scripts/setup_netem.sh
	@echo "==> 网络仿真配置完成"

teardown-netem:
	@echo "==> 清除网络仿真规则..."
	sudo bash scripts/teardown_netem.sh
	@echo "==> 网络仿真规则已清除"

setup-nfqueue:
	@echo "⚠️  此命令需要sudo权限"
	@echo "==> 配置iptables NFQUEUE规则..."
	@echo "请手动执行: sudo bash scripts/setup_nfqueue.sh"

teardown-nfqueue:
	@echo "⚠️  此命令需要sudo权限"
	@echo "==> 清除NFQUEUE规则..."
	@echo "请手动执行: sudo bash scripts/teardown_nfqueue.sh"

# ==============================================================================
# 实验执行
# ==============================================================================

run_exp1:
	@echo "==> Exp-1: 端到端时延拆解"
	@mkdir -p results/exp1
	cargo run --release --bin auth-gateway -- --mode exp1
	@echo "==> Exp-1 完成，数据保存在 results/exp1/"

run_exp2:
	@echo "==> Exp-2: DNS报文大小对比"
	@mkdir -p results/exp2
	python3 scripts/analyze_pcap.py
	@echo "==> Exp-2 完成，数据保存在 results/exp2/"

run_exp3:
	@echo "==> Exp-3: RPC时延vs数据规模"
	@mkdir -p results/exp3
	python3 scripts/benchmark_rpc.py
	@echo "==> Exp-3 完成，数据保存在 results/exp3/"

run_exp4:
	@echo "==> Exp-4: 消融实验"
	@mkdir -p results/exp4
	cargo run --release --bin auth-gateway -- --mode exp4
	@echo "==> Exp-4 完成，数据保存在 results/exp4/"

run_exp5:
	@echo "==> Exp-5: 高并发吞吐量（完整TCP握手）"
	@mkdir -p results/exp5
	@echo "5A: 禁用DNS缓存（最坏情况）..."
	cargo run --release --bin auth-gateway -- --mode exp5a
	@echo "5B: 启用DNS缓存（真实部署）..."
	cargo run --release --bin auth-gateway -- --mode exp5b
	@echo "==> Exp-5 完成，数据保存在 results/exp5/"

plot:
	@echo "==> 生成所有论文图表..."
	python3 scripts/plot_all.py
	@echo "==> 图表生成完成，保存在 results/figures/"

# ==============================================================================
# 清理
# ==============================================================================

clean: teardown-netem teardown-nfqueue
	@echo "==> 清理生成文件..."
	@$(MAKE) -s stop-bind9
	@if [ -f logs/anvil.pid ]; then \
		kill $$(cat logs/anvil.pid) 2>/dev/null || true; \
		rm logs/anvil.pid; \
	fi
	@pkill anvil || true
	cargo clean
	cd contracts && forge clean
	@echo "==> 清理完成"
