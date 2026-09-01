# 自建客户机内核

路由 VM 专用内核（x86_64 / cloud-hypervisor guest），对应 `router.nix` 的
`microvm.router.kernel = "custom"`。官方 Alpine virt 三件套对应 `"alpine"`，
两者并存、可随时切回。

## 为什么自建

Alpine 的 `linux-virt` 把引导链关键驱动编成 `=m`：

```
EXT4_FS=m  JBD2=m  VIRTIO_BLK=m  VIRTIO_NET=m
NF_TABLES=m  NF_CONNTRACK=m  TUN=m  TCP_CONG_BBR=m  NET_SCH_FQ=m
```

这一个事实推导出整条流水线的复杂度：initrd 必须注入 ext4 依赖链才能挂上根盘
（`image/assemble.sh` 的 14 行），rootfs 必须 unsquashfs modloop 再做 modinfo
依赖闭包拷贝（`assemble-rootfs.sh` 的 60 行，且因 `nft_*` 是运行时 modprobe、
闭包覆盖不到，只能整目录兜底拷 `kernel/net` = 7.0M / 376 个 `.ko`），以及内核
与 modloop 的精确版本耦合。

全 builtin 之后这些统统不需要（但 `alpine` 变体仍依赖它们，故代码不能删）：

| | Alpine `linux-virt` | 自建 |
|---|---|---|
| 内核 | 12M | 4.0M |
| initramfs | 10.3M（注入 ext4） | 512 字节未压缩空 cpio 占位 |
| 模块 | 7.0M / 376 个 `.ko` | 112K 纯元数据 / 0 个 `.ko` |
| `=y` / `=m` | 1672 / 896 | 715 / 0 |
| 构建耗时 | — | 122s @ -j20 |

代价是 CVE 响应从 Alpine 转到本仓库，靠跟 LTS 缓解。

## 用法

```bash
./kernel/build.sh                  # 完整构建到 kernel/out/
./kernel/build.sh --config-only    # 只生成并校验 .config（5s，CI 快速门禁）
KVER=6.18.48 ./kernel/build.sh     # 覆盖版本（需先登记 SRC_SHA256）
JOBS=8 ./kernel/build.sh           # 覆盖并行度
```

本地测试（`--assert` 会把启动日志变成断言）：

```bash
test/smoke-test.sh alpine --kernel custom --assert              # 用 release 的自建内核
test/smoke-test.sh alpine --kernel custom --no-initrd --assert  # 连空占位也不传
```

`--kernel` 取变体名（`alpine` | `custom`）而非路径，从 release 下载并校验
sha256 —— 与 `router.nix` 的 `microvm.router.kernel` 同名同义，测的就是消费端
实际会拿到的东西。测本地刚构建、尚未发布的 `kernel/out/vmlinuz-router` 目前
没有直通口子，后续另做。

## 产物

| 文件 | 用途 |
|---|---|
| `vmlinuz-router` | bzImage。qemu `-kernel` 与 CH `--kernel` 都用它，是正常引导路径 |
| `initramfs-empty.cpio` | 512 字节未压缩空 cpio。见下方「为什么还要 initramfs」 |
| `modules/lib/modules/<版本串>/` | depmod 元数据，由 `assemble.sh` 注入 rootfs |
| `config-router` | 完整 `.config`，供查阅与复现（消费端不 fetch） |
| `vmlinux-router` | ELF。当前不发布，见下方「vmlinux 的定位」 |

资产名不带版本号：`custom` 只有一个变体，release tag
（`microvm-router-vm-YYYYMMDD`）已承担版本区分。带版本会让每次 point release
bump 都要手改 `router.nix` 的 url，`sync-flake-sha.py` 的锚定正则也会失配。

## 版本策略：只跟最新 LTS

路由器的失败模式是「跑着突然断网」，不是「缺某个新特性」。LTS 只收 backport
修复，回归面窄；stable 主线每 9~10 周一个大版本，而 virtio / netfilter 恰是
本方案重度依赖、且改动活跃的子系统。

bump 步骤：改 `KVER` → 跑一次拿到实际 sha256 填进 `SRC_SHA256` → 跑
`--config-only` 确认片段仍然全部生效 → 完整构建 + smoke-test `--assert`。

内核与 rootfs 由同一 release tag 一起发布、同批次绑定：模块元数据的目录名是
`uname -r`，内核 bump 必然重建配套 rootfs，二者不解耦。

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

尤其注意 openrc 的 `modules` 服务：它用 `modprobe -q` 且在 `while` 管道里丢弃
返回码，**结构上无法失败**。而 `-q` 会完全吞掉 `FATAL: Module not found` 这条
错误消息 —— 九个模块全部加载失败时，启动日志里只有 `Loading modules [ ok ]`，
一个字的错误都没有。

这意味着模块元数据缺失**连日志断言也检不出来**，只能在 guest 内查状态：

```bash
sh test/verify-guest.sh    # 查 /lib/modules/$(uname -r) 与逐项 modprobe
```

两道防线分工明确：`--assert` 拦启动期可见的失败（缺 syscall、panic、挂不上
根盘），`verify-guest.sh` 拦「启动看着正常但能力不全」的失败。

## 为什么还要 initramfs

引导链全 builtin，本不需要 initramfs。但 microvm.nix 的五个 runner
（cloud-hypervisor / qemu / firecracker / crosvm / stratovirt）都把
`--initramfs` 放在**无条件**参数数组里，且 `initrdPath` 是 `types.path` 没有
null 分支 —— 声明侧无法不传（main 分支与当前 pin 零差异，升级不会自动解决）。

CH 本身是支持的：`--initramfs` 在 `--help` 里是可选项，不传时正常启动。本地
CH v53 实测日志：

```
check access for rdinit=/init failed: -2, ignoring
EXT4-fs (vda): mounted filesystem ... r/w with ordered data mode.
VFS: Mounted root (ext4 filesystem) on device 254:0.
Run /sbin/init as init process
```

所以限制来自封装而非 hypervisor。给一个 50 字节空 cpio 占位：内核找不到
`/init` 就 `ignoring` 继续走 `root=/dev/vda`，五个 runner 全部适用，上游一行
不用改。将来上游把 `--initramfs` 改成条件项后可直接弃用本产物。

## vmlinux 的定位

CH 的 x86_64 分支取 `${kernel.dev}/vmlinux`，但当前喂进去的是 bzImage —— CH
按文件头识别，走 bzImage 分支，文件名与内容不符却无害（`router.nix` 的
`guestKernel` 包装）。

`vmlinux-router` 因此当前不被消费，也不发布。保留构建的理由是它本就是 bzImage
的前置产物（`make bzImage vmlinux` 一条命令），零额外成本，而它是两件事的后路：
将来若切 PVH 直引导，把真 ELF 放进 `$dev/vmlinux` 即可，runner 侧零改动；未
strip 的符号表也是宿主侧 gdb / crash 的来源。

PVH 值不值得上是个真实取舍：它省掉实模式 setup 与自解压，是 CH 视为原生的
协议；但 bzImage 路径已经在跑、踩得更实，换来的那点启动延迟对一台很少重启的
路由器意义有限。`CONFIG_PVH=y` 已在片段里开着，随时可切。
