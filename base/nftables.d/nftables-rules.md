# nftables 规则说明

本文档根据当前目录下的以下配置文件整理生成：

- `00-inet-vars.nft`
- `10-inet-nat.nft`
- `20-inet-filter.nft`

用于说明当前路由器的 nftables 变量定义、NAT 行为、过滤规则和默认放行/丢弃策略。

## 1. 文件职责

### `00-inet-vars.nft`

定义全局变量，供后续 NAT 和过滤规则复用。

主要变量如下：

| 类型 | 变量 | 当前值 |
| --- | --- | --- |
| 接口 | `WAN` | `eth0` |
| 接口 | `LAN` | `eth1` |
| 接口 | `WG` | `wg0` |
| 接口 | `TS` | `ts0` |
| 接口 | `TUN` | `tun0` |
| 端口 | `WG_PORT` | `51820` |
| 端口 | `TS_PORT` | `41641` |
| 端口 | `SSH_PORT` | `22` |
| 端口 | `DNS_PORT` | `53` |
| 地址 | `WG_IP` | `10.10.10.2` |
| 地址 | `ROUTER_LAN_IP` | `192.168.8.1` |
| 地址 | `PROXY_SERVER_IP` | `192.168.8.180` |
| 网段 | `LAN_NET` | `192.168.8.0/24` |
| 网段 | `TS_NET` | `100.64.0.0/10` |
| 网段 | `WG_NET` | `10.10.10.0/24` |
| 集合 | `VPN_NETS` | `{ TS_NET, WG_NET }` |
| 集合 | `WAN_IFS_LIST` | `{ eth0 }` |
| 集合 | `LAN_IFS_LIST` | `{ eth1 }` |
| 集合 | `VPN_IFS_LIST` | `{ wg0, ts0 }` |
| 集合 | `TUN_IFS_LIST` | `{ tun0 }` |
| 集合 | `PROXY_SETS` | `{ 192.168.8.180 }` |
| 路由表 | `ROUTE_TABLE_ID` | `100` |
| 私网 | `PRIVATE_NETS` | `10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10` |

说明：

- 当前默认接口假设仍然是 `WAN=eth0`、`LAN=eth1`。
- `PROXY_SETS`、`ROUTE_TABLE_ID`、`PRIVATE_NETS` 在本目录的 NAT/Filter 文件中暂未直接使用。

## 2. NAT 规则

### `10-inet-nat.nft`

定义 `table inet nat`，包含以下接口集合：

- `lan_interfaces`
- `wan_interfaces`
- `vpn_interfaces`
- `tun_interfaces` 

### `prerouting`

- 类型：`nat hook prerouting`
- 默认策略：`accept`
- 当前未配置 DNAT 或端口转发规则

结论：目前没有做入站端口映射。

### `postrouting`

- 类型：`nat hook postrouting`
- 默认策略：`accept`

当前规则如下：

1. `oifname @wan_interfaces` 且 `meta nfproto ipv4` 时执行 `masquerade`
   - 含义：所有经 WAN 出口的 IPv4 流量都做源地址伪装
   - 作用：LAN/TUN/VPN 侧主机可以通过路由器共享 IPv4 上网

2. `iifname @vpn_interfaces` 且 `oifname @lan_interfaces` 且 `meta nfproto ipv4` 时执行 `masquerade`
   - 含义：VPN 进入、转发到 LAN 的 IPv4 流量也做源 NAT
   - 作用：让 VPN 客户端访问内网时，以路由器 LAN 地址对内通信，避免内网主机缺少回程路由

## 3. 过滤规则

### `20-inet-filter.nft`

定义 `table inet filter`，包含：

- 接口集合：`lan_interfaces`、`wan_interfaces`、`vpn_interfaces`、`tun_interfaces`
- 动态黑名单：`flood_blacklist_v4`、`flood_blacklist_v6`
- `flowtable f`：绑定设备 `{ eth0, eth1 }`，用于 TCP/UDP 转发卸载

---

## 4. INPUT 链说明

`chain input` 挂载到 `hook input`，默认策略为 `drop`。

这表示：所有发往路由器本机的流量，除明确允许外，默认丢弃。

### 基础放行与状态处理

- 放行回环接口 `lo`
- 放行 `established,related`
- 丢弃 `invalid`

### WAN 防护与黑名单

- 丢弃来自 WAN 且源地址已在 `flood_blacklist_v4` / `flood_blacklist_v6` 中的流量
- 明确允许 WAN 进入的 UDP 端口：
  - `51820/udp`，用于 WireGuard
  - `41641/udp`，用于 Tailscale
- 对自 WAN 的新建 TCP SYN来 连接做限速
  - 超过 `100/second`，突发超过 `200 packets`
  - 记录日志
  - 加入动态黑名单
  - 然后丢弃

说明：

- IPv4 SYN Flood 规则排除了 `WG_PORT` 和 `TS_PORT`，但这两个端口本身是 UDP 端口，因此该排除条件对 TCP 实际影响很小。
- IPv6 SYN Flood 规则未做端口排除，直接按新建 TCP SYN 限流。
- 黑名单超时时间为 `1h`。

### ICMP 允许策略

允许来自 WAN 的以下 ICMP/ICMPv6 类型，且按 `5/second`、`burst 10 packets` 限速：

- `echo-request`
- `destination-unreachable`
- `time-exceeded`
- `parameter-problem`

额外允许：

- 来自 `TS_NET` 的 IPv4 ICMP 上述类型，带同样限速
- 来自 WAN 的 IPv6 邻居发现报文：
  - `nd-router-solicit`
  - `nd-router-advert`
  - `nd-neighbor-solicit`
  - `nd-neighbor-advert`

### 管理与基础服务

允许访问路由器本机的服务如下：

| 来源 | 协议/端口 | 条件 |
| --- | --- | --- |
| `LAN` | `tcp/22` | 新建连接，`30/minute`，`burst 20` |
| `TUN` | `tcp/22` | 新建连接，`30/minute`，`burst 20` |
| `VPN` | `tcp/22` | 新建连接，`60/minute`，`burst 30` |
| `TS_NET` | `tcp/22` | 新建连接，`60/minute`，`burst 30` |
| `LAN` | `udp/67-68` | DHCP |
| `LAN` | `udp/53` | DNS |
| `LAN` | `tcp/53` | DNS |
| `TUN` | `udp/53` | DNS |
| `TUN` | `tcp/53` | DNS |

### 其他本机访问放行

- 允许来自 `LAN` 的常见 IPv4 ICMP
- 允许来自 `TUN` 的常见 IPv4 ICMP
- 直接放行来自以下入口接口的其他流量到本机：
  - `vpn_interfaces`
  - `tun_interfaces`
  - `lan_interfaces`

结论：

- WAN 对本机默认只开放 WireGuard、Tailscale 握手和受限 ICMP/ICMPv6。
- LAN / TUN / VPN 到本机相对宽松，除前面单独列出的 SSH、DNS、DHCP 外，后续还有整体 `accept`。

### INPUT 默认处理

未命中上述规则时：

- 记录 `INPUT_DROP` 日志
- 限速 `10/minute`
- 丢弃

---

## 5. FORWARD 链说明

`chain forward` 挂载到 `hook forward`，默认策略为 `drop`。

这表示：所有转发流量都必须显式匹配规则。

### 基础规则

- 对 TCP/UDP 启用 `flow offload @f`
- 放行 `established,related`
- 丢弃 `invalid`
- 对 SYN 包执行 MSS Clamping：`tcp option maxseg size set rt mtu`

### 明确允许的转发方向

| 入接口/源 | 出接口 | 含义 |
| --- | --- | --- |
| `LAN` | `TUN` | 内网流量进入透明代理隧道 |
| `TUN` | `WAN` | 代理后的流量继续出网 |
| `TUN` | `LAN` | 允许隧道侧回到内网 |
| `TS_NET` | `TUN` | Tailscale 来源流量转入透明代理隧道 |
| `LAN` | `LAN` | 同接口 LAN 内部转发 |
| `VPN` | `LAN` | VPN 访问内网 |
| `LAN` | `VPN` | 内网访问 VPN 侧 |

### FORWARD 链特点

- 没有显式的 `LAN -> WAN` 放行规则。
- 没有显式的 `VPN -> WAN` 放行规则。
- 当前设计更像是：
  - LAN 流量优先导入 `TUN`
  - 由 `TUN` 继续出 WAN
  - VPN 主要用于访问内网，而不是直接借道 WAN

这意味着是否能正常上网，还依赖更上层的策略路由、透明代理和接口流向设计。

### FORWARD 默认处理

未命中上述规则时：

- 记录 `FORWARD_DROP` 日志
- 限速 `10/minute`
- 丢弃

---

## 6. OUTPUT 链说明

`chain output` 挂载到 `hook output`，默认策略为 `accept`。

行为：

- 路由器本机发出的流量默认全部允许
- 对 `ct state new` 的新建连接记录日志
- 日志前缀为 `OUTPUT_NEW`
- 日志限速 `5/minute`

---

## 7. 当前策略总结

整体策略可以概括为：

1. 本机输入默认拒绝，WAN 面只开放必要隧道入口和受限 ICMP。
2. 内网、VPN、透明代理接口对路由器本机访问较宽松。
3. 出 WAN 的 IPv4 流量统一做 `masquerade`。
4. VPN 访问 LAN 时额外做一次 IPv4 `masquerade`，简化回程路径。
5. 转发链偏向“LAN -> TUN -> WAN”的代理出口模型，而不是传统“LAN -> WAN”直连模型。
6. 具备基础 SYN Flood 限流、动态黑名单、日志记录和流量卸载能力。

## 8. 需要注意的点

从当前规则看，有几个实现上的注意事项：

1. `prerouting` 为空，说明当前没有端口转发。
2. `flowtable f` 仅绑定 `{ eth0, eth1 }`，不包含 `wg0`、`ts0`、`tun0`。
3. `VPN_IFS_LIST` 包含 `wg0` 和 `ts0`，同时又单独通过 `TS_NET` 允许部分访问，存在“按接口”和“按地址段”混用的设计。
4. `input` 链末尾存在 `iifname @vpn_interfaces accept`、`iifname @tun_interfaces accept`、`iifname @lan_interfaces accept`，因此这些入口到本机的大部分流量都会被放行。
5. 若未来要支持普通 LAN 直连上网，需要确认是否应补充 `LAN -> WAN` 转发规则，或由其他策略路由规则接管。
