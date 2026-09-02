# 重构实施计划：剥离 microvm.nix

> 依据：`docs/refactor-proposal.md`（已审阅，决策锁定）
> 日期：2026-09-01
> 原则：每个任务独立提交、CI 保持绿、随时可停（旧模块与旧资产在新 release 前全程可用）

## 任务总览与依赖

```
T1 内核构建链 ──┐
                ├── T3 镜像装配 + 新 release ──┐
T2 guest 改造 ──┘                              ├── T6 smoke-test 重构 ──┐
T4 NixOS 模块重写 ── T5 flake/CI 调整 ─────────────────────────────┼── T7 端到端验收 ── T8 消费端迁移与清理
                                                                    │
（T4 可与 T1-T3 并行；release 前模块用本地资产占位）                  │
```

## T1：内核构建链（全 builtin 校验 + 去空 initramfs）

**目标**：单一自建内核，零 initramfs 依赖。

**涉及文件**：
- `kernel/config.fragment` —— 核对全部所需功能已 `=y`（virtio_blk/net/balloon、
  ext4 链、netfilter/nft、tun、vsock、串口、overlay 不编）
- `kernel/build.sh` —— 删除 `initramfs-empty.cpio` 生成步骤（若有引用）
- `kernel/verify-config.py`（若存在）—— 保持逐条校验机制

**产出**：`vmlinuz-router`（无 initramfs 可引导）

**验收**：
- [ ] `kernel/build.sh` 本地编译通过
- [ ] 裸启动验证：`cloud-hypervisor --kernel vmlinuz-router --cmdline "root=/dev/vda rw" --disk <旧rootfs>` 到达 login（临时用手工命令，不依赖 smoke-test）

## T2：guest 镜像改造（状态盘挂载 + ro rootfs 写点处理）

**目标**：guest 支持 vdb 状态盘；rootfs `ro` 挂载无写失败。

**涉及文件**：
- `base/` 新增 `local.d/mount-state.start`（两条发行版链共用）：
  挂载 `/dev/vdb` → `/mnt/state`，symlink 状态目录，写 schema 版本检查
- 写点处理：
  - `/etc/mtab` → symlink `/proc/mounts`
  - `/etc/resolv.conf` → symlink `/run/resolv.conf`（udhcpc hook 写入，需验证）
  - `/var/log` → `/mnt/state/log`（决策：持久）
- 状态目录清单（逐服务核对数据目录）：
  `/var/lib/tailscale`、`/etc/cloudflared`、`/etc/ssh`、`/var/lib/misc`、
  `/var/lib/chrony`、`/root/.ssh`
- 状态盘 schema 版本标签（如 `/mnt/state/.schema-version`）

**产出**：镜像内嵌状态盘机制

**验收**（qemu + 临时第二磁盘）：
- [ ] `-drive file=state.qcow2` 启动后 `/mnt/state` 挂载成功
- [ ] ro 启动（`root=/dev/vda ro`）无服务写失败报错
- [ ] 状态盘文件在两次启动间保留

## T3：镜像装配链简化 + 发新 release

**目标**：release 资产收敛为两件套，tag 换新前缀。

**涉及文件**：
- `image/assemble.sh` —— 删除三件套下载、initrd ext4 注入、modloop 注入；
  装配 = rootfs + qcow2 转换
- `image/assemble-rootfs.sh` —— 不再注入 modloop 闭包
- `.github/workflows/build-image.yml` —— release 资产列表更新；tag 前缀
  `router-vm-YYYYMMDD`；sync-flake-sha 适配新模块结构（T4 完成后联调）

**产出**：`router-vm-20260901` release：
`vmlinuz-router` + `<distro>-rootfs.qcow2` + `config-router` + `SHA256SUMS`

**验收**：
- [ ] 本地 `assemble.sh` 产物与旧 release 等效可启动（qemu）
- [ ] CI 手动触发产出新 release
- [ ] 旧 tag 与新 tag 资产均可下载（旧 tag 不可变，回滚可用）

## T4：NixOS 模块重写（`services.router-vm.*`）

**目标**：自研 systemd 单元管理 cloud-hypervisor，能力不降级。

**涉及文件**：
- `nixos-modules/router.nix`（重写）：
  - options：`services.router-vm = { enable, os, cpu, vcpus, mem,
    initialBalloonMem, wanBridge, lanBridge, vmIp, stateDiskSize }`
    （删除 kernel/initrd/kernelVariants/guestKernel）
  - `router-vm-disk.service`（oneshot）：rootfs 只读复制（含内容哈希路径，
    幂等）+ 状态盘创建（qemu-img + mkfs.ext4）
  - `router-vm.service`：CH ExecStart（`--disk readonly=on`、`--balloon
    size=...,deflate_on_oom=true`、`--cpus affinity`、`--api-socket`）、
    ExecStop=ch-remote shutdown-vmm、preStart tap 创建、ExecStopPost 清理
  - `systemd.network`：tap 出现时挂入 br-wan/br-lan（沿用现有思路）
  - deploy 脚本迁移（`alpine-router-deploy` → 新名 `router-vm-deploy`，
    目标 IP/路径引用更新）
- 删除文件：`nixos-modules/cloud-hypervisor-router.nix`（早期草稿，已被取代）、
  `example-host-config.nix`（草稿，按新模块重写为正式示例）

**产出**：新模块可评估、可构建

**验收**：
- [ ] `nix flake check` 通过
- [ ] `nix eval` 检查 systemd unit（ExecStart/ExecStop/preStart/网络配置）
- [ ] fetchurl 指向新 release 资产 + sha256 正确

## T5：flake 与测试配置

**目标**：flake 输入只剩 nixpkgs；测试配置对齐新模块。

**涉及文件**：
- `flake.nix` —— 删除 `microvm` 输入与 `follows`；nixosModules 输出保持
  `router` 名（消费端只改 input 名不改模块引用路径）
- `test-nixos-host.nix` —— 改用 `services.router-vm.*`（桥接配置沿用）
- 删除 `test-microvm.nix`、`test-guest.nix`（microvm 依赖链）
- `.github/workflows/test-router-module.yml` —— 去 microvm 相关步骤，
  验证新模块 unit 生成

**验收**：
- [ ] `nix flake lock` 无 microvm 输入
- [ ] CI test-router-module 绿

## T6：smoke-test.sh 重构

**目标**：两条路径（qemu 交互 / CH 非交互断言），删除内核变体选项。

**涉及文件**：`test/smoke-test.sh`

**改动**：
- 删除 `--kernel` / `--no-initrd` 选项、`kernelVariants` 映射、
  `initramfs-empty.cpio` 相关逻辑（资产表只剩 kernel + rootfs）
- tag 探测前缀改 `router-vm-`
- qemu 路径：保持现状（交互）
- CH 路径 `--assert` 模式：**非交互** —— 后台启动、日志轮询至 `login:` 或
  超时、强制清理、输出日志供断言（不尝试 tee/script 保 TTY，吸取教训）
- 清理当前工作区的 WIP 改动（BOOT_FN 映射、sudo 预检等按新结构重写）

**验收**：
- [ ] qemu：交互登录 + `nft list ruleset` / `rc-status` 验证通过
- [ ] CH `--assert`：启动日志断言通过（无 FATAL/panic/未达 login）
- [ ] `--verify-only` 只下载校验路径通过

## T7：端到端验收（NixOS 宿主）

**目标**：方案 §7 验收标准全部通过。

**验证环境**：`test-nixos-host`（nix build 出 VM，本地嵌套启动）或真实
NixOS 机器（优先）。

**验收清单**（对应方案 §7）：
- [ ] VM 启动、SSH 可达（经 br-lan）
- [ ] ro rootfs 无写失败报错
- [ ] 镜像升级（换 release 资产）后 tailscale/cloudflared 状态保留，
      无需重新 deploy
- [ ] 宿主 reboot 后 VM 自动恢复
- [ ] `systemctl stop` 优雅关机（api-socket 生效，CH 进程退出）
- [ ] 核隔离：`taskset -cp $(pgrep cloud-hypervisor)` 只绑定隔离核
- [ ] balloon：guest 内初始 256M，宿主 OOM 时收缩
- [ ] 状态盘扩容流程（qemu-img resize + resize2fs）文档化并验证

## T8：消费端迁移与清理

**目标**：qnap-nixos-nas 切换完成，旧代码删除。

**涉及**：
- qnap-nixos-nas：flake input `microvm-router-image` → `router-image`
  （URL `github:allenmagic/router-image`），`microvm.router.*` →
  `services.router-vm.*`（提供配置 diff 文档）
- 本仓库：删除旧 `microvm.router` 命名空间残余、microvm 相关注释/文档
- 文档更新：`README.md`（新消费方式、状态盘运维、扩容流程）、
  `docs/quick-start-arch-linux.md`、`docs/verify-on-nixos.md`
- `docs/refactor-proposal.md` 归档标记（已实施）

**验收**：
- [ ] 旧代码删除后 `nix flake check` 仍通过
- [ ] qnap-nixos-nas 使用新模块启动 VM 成功
- [ ] README 消费端示例可直接复制使用

## 回滚与安全网

- T3 之前：旧模块 + 旧 release 全程可用（repo 改名有 GitHub 301 兜底）
- T3 之后：旧 tag 资产保留，旧模块仍指向旧 tag（共存到 T8）
- 每任务独立提交；T4/T5 完成前 flake 保持旧模块可评估
- 若 ro rootfs 写点失控（T2 验收失败）：回退路线 B（builtin initramfs
  叠 overlay），见方案 §5 风险表
