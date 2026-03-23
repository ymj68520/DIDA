# eBPF程序编译Makefile

# 编译器
CLANG ?= clang
LLC ?= llc

# 编译选项
CFLAGS = -O2 -g -Wall -target bpf -c

# 目标文件
TARGET = xdp_whitelist.o

# 源文件
SRC = xdp_whitelist.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CLANG) $(CFLAGS) $< -o $@

clean:
	rm -f $(TARGET)

.PHONY: all clean
