// SPDX-License-Identifier: GPL-2.0
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>

// 白名单映射：key为IPv4地址（网络字节序），value为是否在白名单中（1表示在）
struct {    
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, u32);    // IPv4地址（网络字节序）
    __type(value, u32);  // 1表示在白名单中
} WHITELIST_MAP SEC("maps");

// XDP程序：白名单初筛
SEC("xdp")
int xdp_whitelist(struct xdp_md *ctx) {
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    
    // 解析以太网头部（14字节）
    struct ethhdr *eth = data;
    if ((void *)eth + sizeof(*eth) > data_end) {
        return XDP_PASS;  // 报文太短，交给内核处理
    }
    
    // 只处理IPv4报文
    if (bpf_ntohs(eth->h_proto) != ETH_P_IP) {
        return XDP_PASS;
    }
    
    // 解析IPv4头部
    struct iphdr *ip = data + sizeof(*eth);
    if ((void *)ip + sizeof(*ip) > data_end) {
        return XDP_PASS;
    }
    
    // 只处理TCP SYN报文（协议号6，SYN标志位为1）
    if (ip->protocol != IPPROTO_TCP) {
        return XDP_PASS;
    }
    
    // 解析TCP头部
    struct tcphdr *tcp = (void *)ip + ip->ihl * 4;
    if ((void *)tcp + sizeof(*tcp) > data_end) {
        return XDP_PASS;
    }
    
    // 只处理SYN报文（SYN标志位为1，ACK标志位为0）
    if (!((tcp->syn) && (!tcp->ack))) {
        return XDP_PASS;
    }
    
    // 检查目标IP是否在白名单中
    u32 *value = bpf_map_lookup_elem(&WHITELIST_MAP, &ip->daddr);
    if (value && *value == 1) {
        // 在白名单中，直接放行
        return XDP_PASS;
    }
    
    // 不在白名单中，交给Netfilter队列处理
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
