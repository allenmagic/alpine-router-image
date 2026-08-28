# DNSMASQ.D 知识库

## 概述

dnsmasq 同时承担 LAN 的 **DHCP 分配**与 **DNS 解析**（转发上游公共 DNS），
仅监听 LAN 接口。透明代理/策略分流由 yunshu 容器负责，本服务不参与。

## 关键文件

| 文件 | 作用 | 关键点 |
|------|------|--------|
| `dnsmasq.conf` | 全局监听与加载 | `interface=__LAN_IFACE__` 仅监听 LAN（构建时按 network.env 替换为 eth1）；`bind-dynamic` 适应虚拟化接口时序；`conf-dir=/etc/dnsmasq.d/,*.conf` 加载模块化配置 |
| `dnsmasq.d/00-base.conf` | DHCP 基础配置 | `dhcp-authoritative`、租约文件 `/var/lib/misc/dnsmasq.leases` |
| `dnsmasq.d/10-dhcp-eth1.conf` | LAN 口 DHCP 参数 | 地址池、网关（浮动 IP）/DNS/广播下发、`log-dhcp`（**不配 option 121**，见文件内注释） |
| `dnsmasq.d/10-static.conf` | 固定 IP 分配 | 格式：`dhcp-host=MAC地址,IP地址,设备名,租期(可选)` |
| `dnsmasq.d/20-upstream-dns.conf` | 上游 DNS 转发目标 | 阿里云 223.5.5.5/223.6.6.6、腾讯 119.29.29.29/182.254.116.116 |

## DHCP 行为（基于 00-base.conf + 10-dhcp-eth1.conf）

- **权威 DHCP**: `dhcp-authoritative` 加速客户端获取 IP。
- **地址池**: `192.168.10.100-192.168.10.200`，租期 12 小时（`network.env` 的 `DHCP_RANGE_*`）。
- **下发网关**: `__LAN_GATEWAY__`（浮动 IP `192.168.10.254`，VRRP 主备持有：yunshu MASTER / 本 VM BACKUP）。
- **下发 DNS**: `__LAN_IP__`（`192.168.10.1`，即路由器自身——dnsmasq 转发上游解析）。
- **租约文件**: `/var/lib/misc/dnsmasq.leases`。

## 约定

- LAN 接口固定为 `eth1`，WAN 接口固定为 `eth0`（权威源 `network.env`，`network.sh` 构建时替换全部 `__XXX__` 占位符）。
- DNS 由 dnsmasq 自身解析并转发 `20-upstream-dns.conf` 的上游，不要在别处再启 DNS 服务（53 端口冲突）。
- 修改 DHCP 网段/地址池时同步更新：`network.env` + nftables 变量（`__LAN_NET__` 等）+ NAS 侧 `modules/network/bridges.nix` 等。

## 反模式（本项目）

- 不要在 WAN 口开启 DHCP（`interface` 已限定 LAN，保持）。
- 不要在 dnsmasq 里关闭 DNS（`port=0` 是 r3s/sing-box 时代的做法，当前 dnsmasq 就是 DNS 服务）。
- 不要在这里配置透明代理相关劫持——那是 yunshu 容器的职责。
