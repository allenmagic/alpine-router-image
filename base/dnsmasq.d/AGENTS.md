# DNSMASQ.D 知识库

## 概述
dnsmasq 仅用于 LAN 的 DHCP 分配，DNS 解析由 sing-box 提供。
`config/dnsmasq.conf` 通过 `port=0` 关闭 DNS 监听，仅保留 DHCP 功能。

## 关键文件
| 文件 | 作用 | 关键点 |
|------|------|--------|
| `config/dnsmasq.conf` | 全局监听与加载 | `port=0` 关闭 DNS；`interface=eth1` 仅监听 LAN；`no-dhcp-interface=eth0` 禁止 WAN DHCP；`conf-dir=` 加载模块化配置 |
| `config/dnsmasq.d/00-base.conf` | DHCP 基础配置 | 地址池、网关/DNS 下发、租约文件位置 |
| `config/dnsmasq.d/10-static.conf` | 固定 IP 分配 | 格式：`dhcp-host=MAC地址,IP地址,设备名,租期(可选)` |

## DHCP 行为（基于 00-base.conf）
- **权威 DHCP**: `dhcp-authoritative` 加速客户端获取 IP。
- **地址池**: `192.168.10.100-192.168.10.200`，租期 24 小时。
- **下发网关**: `dhcp-option=option:router,192.168.8.1`。
- **下发 DNS**: `dhcp-option=option:dns-server,192.168.8.1`（DNS 实际由 sing-box 监听 53）。
- **租约文件**: `/var/lib/misc/dnsmasq.leases`。

## 约定
- LAN 接口固定为 `eth1`，WAN 接口固定为 `eth0`
- 安装脚本会检测网络接口，如果是双网口则默认配置第一个网口为WAN,第二个为LAN。具体参考安装脚本设置。
- 需同步更新 nftables 变量。
- DNS 监听已关闭，新增 DNS 相关配置不会生效。

## 反模式（本项目）
- 不要在 dnsmasq 中重新启用 DNS（`port=0` 应保持）。
- 不要在 WAN 口开启 DHCP（`no-dhcp-interface=eth0` 应保持）。
