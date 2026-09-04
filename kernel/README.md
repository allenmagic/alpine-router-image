# 自建客户机内核

路由 VM 专用内核（x86_64 / cloud-hypervisor guest）。重构后这是**唯一**内核：
Alpine 官方 virt 三件套变体已整体移除（决策见 `docs/refactor-proposal.md` §3.4），
`nixos-modules/router.nix` 直接 fetchurl `vmlinuz-router`，无内核变体选项。

## 为什么自建

Alpine 的 `linux-virt` 把引导链关键驱动编成 `=m`：

```
EXT4_FS=m  JBD2=m  VIRTIO_BLK=m  VIRTIO_NET=m
NF_TABLES=m  NF_CONNTRACK=m  TUN=m  TCP_CONG_BBR=m  NET_SCH_FQ=m
```

这一个事实曾推导出整条流水线的复杂度：initrd 必须注入 ext4 依赖链才能挂上根
盘，rootfs 必须 unsquashfs modloop 再做 modinfo 依赖闭包拷贝（且因 `nft_*` 是
运行时 modprobe、闭包覆盖不到，只能整目录兜底拷 `kernel/net` = 7.0M / 376 个
`.ko`），以及内核与 modloop 的精确版本耦合。

全 builtin 之后这些统统不需要，装配链只剩「rootfs + qcow2 转换」。
2026-09 裁剪审计进一步把 MODULES 与虚拟设备死代码清零（CH 只挂
balloon + 8250 串口，无 rng/vsock/virtio-console），guest 内不再有
kmod 包、openrc modules 服务与 /lib/modules 目录：

| | 旧（Alpine `linux-virt`） | 自建 | 裁剪后 |
|---|---|---|---|
| 内核 | 12M | 4.0M | 3.8M |
| initramfs | 10.3M（注入 ext4） | 无 | 无 |
| 模块 | 7.0M / 376 个 `.ko` | 112K 纯元数据 / 0 个 `.ko` | 无（MODULES=n） |
| `=y` / `=m` | 1672 / 896 | 715 / 0 | 678 / 0 |
| 构建耗时 | — | 122s @ -j20 | — |

代价是 CVE 响应从 Alpine 转到本仓库，靠跟 LTS 缓解（CI 缓存键含 KVER，
bump 即自动重编）。

## 用法

```bash
./kernel/build.sh                  # 完整构建到 kernel/out/
./kernel/build.sh --config-only    # 只生成并校验 .config（5s，CI 快速门禁）
KVER=6.18.48 ./kernel/build.sh     # 覆盖版本（需先登记 SRC_SHA256）
JOBS=8 ./kernel/build.sh           # 覆盖并行度
```

本地启动测试（smoke-test 从 release 下载校验同一资产，测的就是消费端
实际会拿到的东西；本地刚构建、尚未发布的 `kernel/out/vmlinuz-router` 用
`--local-kernel` 直通，跳过 release 内核的下载与校验）：

```bash
test/smoke-test.sh alpine                                   # qemu 交互
test/smoke-test.sh alpine --backend cloud-hypervisor --assert  # CH 非交互断言
# 本地内核直通（rootfs 无 /lib/modules，内核与镜像完全解耦，本地内核可直测）
test/smoke-test.sh alpine --local-kernel kernel/out/vmlinuz-router --backend cloud-hypervisor --assert
```

## 产物

| 文件 | 用途 |
|---|---|
| `vmlinuz-router` | bzImage。qemu `-kernel` 与 CH `--kernel` 都用它（CH 按文件头识别），是唯一引导路径 |
| `config-router` | 完整 `.config`，供查阅与复现（消费端不 fetch） |
| `vmlinux-router` | ELF。不发布，见下方「vmlinux 的定位」 |

资产名不带版本号：内核只有一个变体，release tag（`router-vm-YYYYMMDD`）已
承担版本区分。带版本会让每次 point release bump 都要手改 `router.nix` 的 url，
`sync-flake-sha.py` 的锚定正则也会失配。版本可从 config-router 内容与
guest 的 `uname -r` 查得。

版本串命名：`config.fragment` 的 `CONFIG_LOCALVERSION="-dange-router-vm"`
（仿 WSL 的 `-microsoft-standard-WSL2`），guest 内 `uname -r` 显示
`6.18.48-dange-router-vm`。改名只动这一行（前导连字符必须自写）；
KVER bump 不影响命名。

## 版本策略：只跟最新 LTS

路由器的失败模式是「跑着突然断网」，不是「缺某个新特性」。LTS 只收 backport
修复，回归面窄；stable 主线每 9~10 周一个大版本，而 virtio / netfilter 恰是
本方案重度依赖、且改动活跃的子系统。

bump 步骤：改 `KVER` → 跑一次拿到实际 sha256 填进 `SRC_SHA256` → 跑
`--config-only` 确认片段仍然全部生效 → 完整构建 + smoke-test `--assert`。

内核与 rootfs 由同一 release tag 一起发布（同批次资产便于消费端一次 fetch
两件套）；构建已解耦——MODULES=n 后 guest 内无 `/lib/modules`，内核 bump
不必重建 rootfs（CI 中 kernel 与 build 作业完全并行）。

## config.fragment 的三类陷阱

`allnoconfig` 会把**每一个带 prompt 的符号一律置 n**，无论 Kconfig 里写的是
`default y` 还是 `def_bool y`。`verify-config.py` 只能证明「声明过的项生效了」，
永远无法证明「声明集合是完整的」。已踩过三次，三种不同成因：

1. **`if EXPERT` prompt 门控** — 没开 `CONFIG_EXPERT=y` 时符号不可设，片段指令
   被忽略、`default y` 生效。开了 EXPERT 反而解锁 prompt，于是被 allnoconfig
   关掉。`FILE_LOCKING` 属此类：丢了它 openrc 启动时 flock 全部
   `Function not implemented`，启动卡在 boot runlevel。
2. **`def_bool y` + 无条件 prompt** — 与 EXPERT 无关，从来就是 n。`SECCOMP`
   属此类：Alpine 的 openssh 编译时带 `--with-sandbox=seccomp_filter`，缺它
   sshd 每次连接的 privsep 子进程都会被自己的沙箱初始化打死。
3. **`default <另一符号>` + 无条件 prompt** — `RTC_INTF_DEV` 属此类：驱动照样
   打印 `registered as rtc0`，但 `/dev/rtc0` 不存在，hwclock 静默失败。

这类问题的共同特征是**能编译、能启动、服务全 `[ ok ]`**。所以真正的防线不是
穷举符号（做不到），而是 `test/smoke-test.sh --assert` 把启动日志变成断言。

历史上 openrc 的 `modules` 服务用 `modprobe -q` 且在 `while` 管道里丢弃返回
码，**结构上无法失败**——九个模块全部加载失败时日志里只有
`Loading modules [ ok ]`，只能靠 `verify-guest.sh` 在 guest 内逐项 modprobe。
2026-09 裁剪后 MODULES=n，该静默失败通道随 modules 服务、kmod 包、
`/lib/modules` 目录一起移除；verify-guest.sh 改用 `/sys/module/<名>` 判定
builtin 能力（builtin 代码同样注册 sysfs 目录，且不依赖任何用户态工具）：

```bash
sh test/verify-guest.sh    # 查 /sys/module 下的关键 builtin 能力
```

两道防线分工明确：`--assert` 拦启动期可见的失败（缺 syscall、panic、挂不上
根盘、ro 写失败），`verify-guest.sh` 拦「启动看着正常但能力不全」的失败。

## 无 initramfs（旧占位的去留）

引导链全 builtin，本不需要 initramfs。旧架构里 microvm.nix 的 runner 无条件传
`--initramfs`、`initrdPath` 类型无 null 分支，被迫发布 512 字节空 cpio 占位
（内核找不到 `/init` 打印 `rdinit=/init failed: -2, ignoring` 后正常走
`root=/dev/vda`）。剥离 microvm 后 CH 由模块直接驱动，`--initramfs` 参数
不传即可，占位资产随旧 release 冻结（旧 tag 不可变，回滚不受影响）。

`CONFIG_BLK_DEV_INITRD=y` 仍保留：它是 ro rootfs 写点失控时「builtin
initramfs 叠 overlay」回退路线（`docs/refactor-proposal.md` §5）的内核侧
前提，成本只有几 KB。

## vmlinux 的定位

CH 直接 `--kernel` bzImage（按文件头识别）。`vmlinux-router` 当前不被消费，
也不发布。保留构建的理由是它本就是 bzImage 的前置产物（`make bzImage vmlinux`
一条命令），零额外成本，而它是两件事的后路：将来若切 PVH 直引导（
`CONFIG_PVH=y` 已在片段里开着），把真 ELF 交给 CH 即可；未 strip 的符号表
也是宿主侧 gdb / crash 的来源。

PVH 值不值得上是个真实取舍：它省掉实模式 setup 与自解压，是 CH 视为原生的
协议；但 bzImage 路径已经在跑、踩得更实，换来的那点启动延迟对一台很少重启的
路由器意义有限。
