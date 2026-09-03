# 重构方案：剥离 microvm.nix，直接用 cloud-hypervisor 管理路由 VM

> 状态：**已实施**（2026-09-03，T1-T8 完成；宿主侧验收见 docs/verify-on-nixos.md，
> 消费端迁移见 docs/migration-from-microvm.md）
> 日期：2026-09-01（§3.3 于 2026-09-02 修订为 sops 方案）

## 1. 现状分析

### 1.1 当前架构

```
NixOS 宿主
└── microvm.nix host 模块（外部 flake 依赖）
    └── microvm.vms.alpine-router（由本仓库 nixos-modules/router.nix 声明）
        ├── tap 创建 / 网桥挂接（microvm 负责）
        ├── systemd 单元生成（microvm 负责）
        ├── balloon + OOM 放气（microvm 负责）
        ├── 优雅关机 API socket（microvm 负责）
        └── cloud-hypervisor 启动（vmlinuz + initrd + rootfs 副本）
```

依赖链：`qnap-nixos-nas` → `router-image`（本仓库）→ `microvm.nix` → `nixpkgs`

### 1.2 为 microvm.nix 妥协而产生的复杂度

| 妥协点 | 现状 | 原因 |
|---|---|---|
| `initramfs-empty.cpio`（512B 占位） | custom 内核全 builtin 本不需要 initramfs，仍要发布并传递空 cpio | microvm.nix 五个 runner 无条件传 `--initramfs`，`initrdPath` 类型无 null 分支 |
| `guestKernel` 包装 derivation | 需要 `$out/bzImage` + `$dev/vmlinux` 双输出 | CH runner 从 `${kernel.dev}/vmlinux` 取内核 |
| 完整 NixOS 模块求值 | `microvm.vms.*.config` 按 NixOS guest 系统求值 | microvm.nix 面向 NixOS-guest 场景，本仓库 guest 是预构建镜像，只用到其中极小子集 |
| flake 双输入 | `microvm` flake 输入 + `follows` 约束 | 只为拿到 host 模块 |

### 1.3 持久化现状的问题

当前「持久化」= `alpine-router-disk.service` 把 release 镜像复制到
`/var/lib/alpine-router/rootfs-<内容哈希>.qcow2`，VM 以读写模式挂载整个 rootfs：

- ✅ 实现简单：所有状态天然落盘
- ❌ **镜像升级 = 状态清零**：新哈希 → 新路径 → tailscale/cloudflared 用户状态、
  ssh host key、dnsmasq 租约全部丢失，需要重新 deploy 密钥、重新登录 tailscale
- ❌ 配置漂移：guest 内任何手工修改都停留在 rootfs 副本里，无法与 release 镜像区分
- ❌ 回滚不完整：rollback 到旧 generation 能恢复旧 rootfs，但期间产生的新状态
  （如新 tailscale 节点密钥）留在新 rootfs 副本里

### 1.4 结论

microvm.nix 面向的场景（NixOS guest、store 共享、多 hypervisor 抽象）与本仓库
实际需求（预构建镜像 + 一个固定 hypervisor + 状态分离）重叠很小，却引入了上述
全部妥协。剥离后复杂度显著下降，且 NixOS 官方已有 `cloud-hypervisor` 包
（`pkgs.cloud-hypervisor`），直接消费即可。

## 2. 重构目标

1. **去掉 microvm.nix 依赖**：flake 输入从 3 个减到 1 个（仅 nixpkgs），
   `nixos-modules/router.nix` 自行生成 systemd 单元管理 cloud-hypervisor
2. **状态分离**：rootfs 只读（release 镜像原样使用），新增独立状态盘 vdb，
   镜像升级不再丢失 tailscale/cloudflared 状态
3. **能力不降级**：CPU 核隔离、balloon 动态内存、OOM 放气、tap+网桥、
   优雅关机，全部保留
4. **测试脚本重做**：smoke-test.sh 简化为两条路径 —— qemu（交互验证）与
   cloud-hypervisor（与生产同参数的启动验证）
5. **消费端接口平滑**：qnap-nixos-nas 迁移成本最小化（新命名 +
   文档提供配置 diff）

## 3. 目标架构

### 3.0 集成形式（已决）

- **NixOS module 形式**（`services.router-vm.*`），经 flake input 集成到
  qnap-nixos-nas；**不上行 nixpkgs**（资产指向本仓库 release、sha256 同步
  机制仓库本地、场景太特定），只消费 `pkgs.cloud-hypervisor`
- **扁平单 VM 选项**，不用 microvm 式 `vms.<name>` attrsOf：单宿主单路由器
  是实际场景，去掉 name 参数化（tap/unit/socket 路径固定）；将来需要多 VM
  时选项层再演进
- **不做 runner package**：systemd 生命周期、tap/网桥编排、磁盘准备必须
  落在 module config 里；本地启动验证由 smoke-test.sh 承担
- **仓库已改名**：`allenmagic/microvm-router-image` → `allenmagic/router-image`
  （2026-09-01 完成，GitHub 301 重定向保证旧链接可用；仓库内引用已同步；
  消费端 flake 输入改为 `inputs.router-image.url =
  "github:allenmagic/router-image"`）
- **tag 前缀**：下一次发版起 `router-vm-YYYYMMDD`（旧 tag
  `microvm-router-vm-*` 保留不动；smoke-test 探测逻辑随重构更新）

### 3.1 模块结构

```
nixos-modules/router.nix（重写）
├── options.services.router-vm
│   ├── enable / os（沿用）
│   ├── cpu / vcpus / mem / initialBalloonMem（沿用）
│   ├── wanBridge / lanBridge / vmIp（沿用）
│   └── stateDiskSize（新增，默认 2G）
│   （kernel / initrd 选项删除——单一自建内核，见 §3.4）
└── config
    ├── systemd.services.router-vm-disk（改：rootfs 只读复制 + 状态盘创建）
    ├── systemd.services.router-vm（新：直接 ExecStart cloud-hypervisor）
    ├── systemd.network（tap 挂桥，沿用思路）
    └── deploy 脚本（沿用，改 VM 名引用）
```

### 3.2 systemd 单元设计

```ini
[Unit]
Description=Router VM (cloud-hypervisor)
After=router-vm-disk.service network.target
Requires=router-vm-disk.service

[Service]
Type=simple
ExecStart=cloud-hypervisor \
    --kernel <release 资产> \
    --cmdline "console=ttyS0 root=/dev/vda rootfstype=ext4 ro" \
    --disk path=<rootfs 只读副本>,readonly=on \
    --cpus boot=2,affinity=[0@[<isolcpu>]] \
    --memory size=512M \
    --balloon size=256M,deflate_on_oom=true \
    --net tap=<wan tap>,mac=... \
    --net tap=<lan tap>,mac=... \
    --serial file=/run/router-vm/console.log \
    --api-socket /run/router-vm/api.sock
ExecStop=ch-remote --api-socket /run/router-vm/api.sock shutdown-vmm
Restart=on-failure
```

要点：

- **tap 创建**：`preStart` 里 `ip tuntap add ... mode tap`，`ExecStopPost` 清理；
  桥接仍由 networkd 在 tap 出现时自动挂入（沿用现有 `50-router-*` 思路，
  去掉 microvm 的 tap 创建职责）
- **优雅关机**：`--api-socket` + `ch-remote shutdown-vmm`（microvm 内部也是
  这么做的，我们直接接管）
- **串口落盘**：`--serial file=...` 替代 microvm 的 pty 管理；宿主可
  `tail -f` 查看，网络故障时仍有恢复通道（guest 内 ttyS0 getty 保留）
- **重启语义**：镜像升级 → 哈希路径变化 → ExecStart 变化 → 自动重启
  （沿用现有机制，改在 ExecStart 内联，不再需要独立 disk 服务的间接层）

### 3.3 存储与持久化（sops 方案，2026-09-02 修订）

**决策：guest 完全无状态，无 vdb 状态盘。** 持久化数据全部由宿主
sops-nix 管理（加密进 git），deploy 时注入 guest 的 `/run`（tmpfs）。

**修订原因**：状态盘方案在实测中暴露问题——(a) ro rootfs 上运行期
无法创建挂载点与符号链接，全部依赖构建期烙入；(b) 硬断电后 ext4
日志恢复丢数据（实测：schema 文件变空、注入文件消失）。而本场景的
持久化数据只有「密钥与登录凭据」一类纯文本，sops-nix 是更合适的归宿。

```
宿主 NixOS（sops-nix）
├── secrets.yaml（加密进 git）：SSH_PUBLIC_KEY / TAILSCALE_AUTH_KEY /
│   CLOUDFLARED_TOKEN
├── 激活时解密到 /run/secrets/（宿主）
└── router-vm-deploy（systemd，VM 启动后 scp 注入 guest）
    └── 复用 deploy-assets（install.sh + secrets.sh），密钥来源从 env 文件
        换成宿主 /run/secrets/
guest（ro rootfs，无 vdb，完全无状态）
├── 构建期烙入的符号链接（可写目录 → /run tmpfs）：
│     /var/lib/tailscale /etc/cloudflared /var/lib/misc /var/lib/chrony
│     /var/log /var/tmp /root/.ssh /etc/tailscale/authkey
├── sshd host key：sshd-keys 服务生成在 /run/ssh/（每次启动更换，
│     deploy 通道用 root/root 密码 + StrictHostKeyChecking=no）
└── 重启后：密钥消失 → 宿主重新 deploy 恢复（幂等）
```

**deploy 语义变化**：
- 密钥注入仍是唯一「部署」动作，但**每次 VM 重启后都要重新 deploy**
  （tmpfs 清空）。宿主侧做成 systemd 服务（VM 起来后自动跑），操作者
  无感知；或手动 `router-vm-deploy`
- tailscale 登录改为**手动**：authkey 经 config.json 的 `file:` 机制被
  tailscaled 读取，操作者 `ssh root@<VM> 'tailscale up'` 触发登录。
  接受节点 churn（每次重启 = 新节点身份，旧节点过期消失；hostname
  固定，管理台可辨）
- cloudflared 注入后自动重启服务（无登录步骤，保持现状）

**rootfs 只读（路线 A：`ro` 挂载 + 定向处理写点）**：

- 内核 `root=/dev/vda ro` 直接挂载；**不用 overlay** —— 无 initramfs 时
  已挂载的根无法在用户态叠 overlay（microvm 的 overlay 依赖 NixOS 的
  initrd stage-1，砍掉 initrd 后此路不通；builtin initramfs 方案作为
  写点失控时的回退，见 §5 风险）
- 易失写点归 tmpfs / symlink（构建期烙入）：
  - `/etc/mtab` → symlink `/proc/mounts`
  - `/etc/resolv.conf` → symlink `/run/resolv.conf`（udhcpc hook 写入）
  - 上述状态目录 → `/run/...`
- openrc 的 tmpfiles（Create Volatile Files）已覆盖 /run 类易失写

### 3.4 内核：单一自建内核（砍掉 alpine 变体）

**决策**：只保留 `kernel/build.sh` 自建内核（跟最新 LTS，全 builtin），
不传 initramfs；Alpine 官方 virt 内核变体整体移除。

- release 资产变为：`vmlinuz-router` + `<distro>-rootfs.qcow2` +
  `config-router` + `SHA256SUMS`
- `image/assemble.sh` 砍掉：三件套下载、initrd 注入 ext4 依赖链、modloop
  注入 —— 装配只剩 rootfs + qcow2 转换
- rootfs 不再携带双模块树（只保留自建内核的 /lib/modules/<版本串> 元数据）
- 模块与 smoke-test 的 `--kernel` / `--no-initrd` 选项、`kernelVariants`
  表全部删除
- CVE 响应完全落在 LTS bump（CI 已有缓存键含 KVER 的自动重编机制）

### 3.5 测试策略

`test/smoke-test.sh` 重构为两条路径：

| 路径 | 场景 | 交互 | 断言 |
|---|---|---|---|
| `--backend qemu` | 本地交互验证（登录、nft、rc-status） | ✅ 支持 | ✅ |
| `--backend cloud-hypervisor` | 与生产同参数的启动验证 | ❌ 不支持（串口输出落日志） | ✅ 启动日志断言 |
| NixOS 宿主（新） | `nix build` 出宿主 VM 或真实宿主验证 | 经 SSH | 手工 |

- qemu 路径：保持不变（现已是稳定路径）
- CH 路径：直连 `/dev/tty` 时交互可用（实测），但 `--assert` 下重定向后
  不可交互 —— 因此 CH 路径的 `--assert` 模式**明确定位为非交互**：
  后台启动 → 轮询日志直到 `login:` 或超时 → 强制清理，输出日志供断言
- 之前的教训：不再尝试 tee/script/process substitution 保持 TTY ——
  CH 断言模式只做「能不能启动到 login」，交互测试归 qemu
- `--kernel` / `--no-initrd` 选项删除：内核唯一（自建 vmlinuz-router），
  无 initramfs

### 3.6 CI 调整

- `test-router-module.yml`：去掉 microvm.nix 输入，改验证新模块的
  systemd 单元生成（`nix eval` 检查 ExecStart/ExecStop/网络配置）
- `build-image.yml`：release 资产收敛为 `vmlinuz-router` +
  `<distro>-rootfs.qcow2` + `config-router` + `SHA256SUMS`（vmlinuz-virt /
  initrd / initramfs-empty.cpio / modloop 相关步骤全部移除）
- 新增：NixOS 宿主 VM 构建（test-nixos-host 改为使用新模块，可在 CI 里
  `nix build` 出 VM 脚本验证配置合法性）

## 4. 迁移路径

1. **第 1 步**：重写 `nixos-modules/router.nix`（新命名空间，与旧模块并存）
2. **第 2 步**：guest 镜像无状态化（run-state 目录 + /run 符号链接 +
   ro 写点处理，两条发行版链共用）+ deploy 注入路径切换
3. **第 3 步**：`flake.nix` 去 microvm 输入，更新 CI、test-nixos-host
4. **第 4 步**：smoke-test.sh 重构（qemu 保留 / CH 简化为非交互断言）
5. **第 5 步**：qnap-nixos-nas 消费端切换（一次性配置变更；宿主侧接入
   sops-nix + router-vm-deploy 服务）
6. **第 6 步**：删除旧 `microvm.router` 命名空间与 test-microvm.nix

## 5. 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| balloon 的 OOM 放气需要宿主侧监听 virtio-balloon eventfd（microvm 有现成实现） | 内存压力下 VM 无法自动收缩 | CH 原生支持 `deflate_on_oom=true`，实测验证；不行则宿主侧写小型监听器（microvm 的实现可参考移植） |
| `--api-socket` 优雅关机在极端情况下挂起 | systemd stop 卡住 | `TimeoutStopSec` + `ExecStopPost` 兜底 SIGKILL |
| ro rootfs 写点清单失控（漏判的服务写 /etc 或 /var 失败） | 个别服务启动报错或行为异常 | 逐服务核对清单（§7 验收项）；失控则回退到 builtin initramfs 叠 overlay 方案 |
| tailscale 节点 churn（每次重启新节点身份） | 管理台出现过期节点；authkey 消耗 | 可复用 authkey + hostname 固定；不可接受时升级为「tailscaled.state 单独小状态盘」 |
| 宿主 sops 密钥丢失 / VM 重启后 deploy 未自动跑 | guest 无密钥、tailscale 离线 | sops 加密文件进 git（可恢复）；deploy 做成 systemd 服务随 VM 自动执行 |
| CH 随 nixpkgs 升级破坏参数语法（如 `--cpus affinity`） | VM 起不来 | CI 的 NixOS 宿主启动测试先于生产暴露；应急时 flake 临时 pin CH 版本 |

## 6. 已决事项（审阅确认）

1. **选项命名空间**：新命名 `services.router-vm.*`（诚实反映不再依赖
   microvm）；qnap-nixos-nas 是唯一消费端，文档提供一行配置 diff。
2. **内核**：砍掉 alpine virt 变体，单一自建内核（全 builtin、无
   initramfs）。见 §3.4。
3. **rootfs 只读**：路线 A —— `ro` 挂载 + 定向 symlink + tmpfs，
   不用 overlay。见 §3.3。base 配置维持「CI 烙进镜像」，不做宿主侧
   overlay 层（避免 OS/配置双通道版本漂移）。
4. **持久化（修订）**：guest 完全无状态，**不用状态盘**；密钥类数据由
   宿主 sops-nix 管理、deploy 注入 /run。tailscale 节点 churn 接受
   （方案 A），必要时升级为单文件状态盘。见 §3.3。
5. **CH 版本**：跟随 nixpkgs（`pkgs.cloud-hypervisor`），CI 启动测试守护，
   应急时临时 pin。

## 7. 验收标准

- [ ] `nix flake check` 通过（flake 输入只剩 nixpkgs）
- [ ] release 资产 = kernel + rootfs 两件套（无 initrd / 空占位 / modloop）
- [ ] NixOS 宿主（test-nixos-host 或真实机器）上 VM 启动、SSH 可达
- [ ] ro rootfs：guest 启动无写失败报错（mtab/resolv.conf/日志写点已定向处理）
- [ ] deploy 注入：authorized_keys / tailscale authkey / cloudflared token
      写入成功（经符号链接落 /run）
- [ ] 手动 `tailscale up` 登录成功（authkey 经 config.json file: 机制生效）
- [ ] 宿主 reboot 后 VM 自动恢复，deploy 服务自动补注入（systemd 依赖正确）
- [ ] 优雅关机：`systemctl stop` 后 CH 进程退出（api-socket 生效）
- [ ] 核隔离：`taskset -cp $(pgrep cloud-hypervisor)` 显示只绑定隔离核
- [ ] balloon：`free -h` 在 guest 内显示初始 256M，宿主 OOM 时收缩
- [ ] smoke-test.sh：qemu 交互登录 + CH 断言模式均通过
- [ ] qnap-nixos-nas 迁移完成，旧模块删除
