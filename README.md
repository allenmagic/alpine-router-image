# microvm-router-image

Alpine 路由 VM 的**唯一仓库**：镜像生产（CI）+ 消费端声明（flake 模块）。
rootfs 构建链移植自
[nanopi-r3s-rootfs](https://github.com/allenmagic/nanopi-r3s-rootfs)，
并按 VM 场景收敛为 **x86_64 专用**（无跨架构/binfmt/qemu 机制），
双发行版链（Alpine / Gentoo，均为 musl + OpenRC）；
装配 Alpine 官方 virt 三件套，产出可启动的 VM 镜像 release asset。

## 仓库分工

| 环节 | 位置 |
|---|---|
| rootfs 构建 + virt 三件套装配 → release | 本仓库 CI（`image/assemble.sh`） |
| microvm 消费端声明（fetchurl/CH 参数/disk-prep/tap 挂桥） | 本仓库 `nixosModules.router` |
| 密钥注入 | 本仓库 `deploy-assets/`（模块内打包为 deploy 资产；密钥经宿主 env 文件注入，600 权限不进 git/store） |
| 包集（package.list） | 本仓库 `distros/{alpine,gentoo}/package.list`（双链各自维护，r3s 一次性拷贝后已按需分叉） |

## 消费端使用（flake 模块）

```nix
# 宿主 flake
inputs.microvm-router-image.url = "github:allenmagic/microvm-router-image";

# 宿主模块
imports = [ inputs.microvm-router-image.nixosModules.router ];
microvm.router = {
  enable = true;

  os = "alpine";           # 客户机发行版：alpine（默认）/ gentoo（均为 musl+OpenRC）
  cpu = 0;                 # isolcpus 独占核（默认 0；vcpu0 pin 到此核）
  vcpus = 2;               # vCPU 总数（默认 2：vcpu0 独占 + 其余动态调度）
  mem = 512;               # guest 内存上限 MB（默认 512）
  initialBalloonMem = 256; # 初始 balloon MB，128M 对齐（默认 256）

  wanBridge = "br-wan";    # WAN 侧宿主桥（默认 br-wan）
  lanBridge = "br-lan";    # LAN 侧宿主桥（默认 br-lan）

  # 镜像资产默认从本仓库 release fetchurl（tag+sha256 模块内锁定）；
  # 本地调试（如 CI 不可用）时覆盖：
  # kernelFile  = /path/to/vmlinuz-virt;
  # initrd      = /path/to/initrd;
  # rootfsImage = /path/to/alpine-router-rootfs.qcow2;
};
```

镜像 release 的 tag 与三处 sha256 硬编码在模块内（`nixos-modules/router.nix`），
**CI 出 release 后自动同步**（`image/sync-flake-sha.py`，幂等）——宿主升级只需
`nix flake update`。

镜像更新 → 状态盘路径（含内容哈希）变化 → CH 命令行变化 → VM 自动重启；
旧镜像文件保留，宿主 rollback 直接复用。

## 构建流程（本地）

```bash
# 1. 构建 rootfs（架构固定 x86_64，无需 ARCH 参数；双链二选一）
sudo -E PACK=1 bash distros/alpine/build.sh    # 产物 build/alpine/alpine-rootfs-minimal.tar.xz
sudo -E PACK=1 bash distros/gentoo/build.sh    # 产物 build/gentoo/gentoo-rootfs-minimal.tar.xz

# 2. 装配 VM 镜像（下载官方三件套 + initrd 注入 ext4 + rootfs 装配 + qcow2；
#    末尾参数为发行版，决定产物命名）
./image/assemble.sh build/alpine/alpine-rootfs-minimal.tar.xz dist alpine
# 产物：dist/{vmlinuz-virt, initrd, alpine-rootfs.qcow2, SHA256SUMS}
# gentoo：./image/assemble.sh build/gentoo/gentoo-rootfs-minimal.tar.xz dist gentoo
```

CI 手动触发后：构建 → release 上传（tag `microvm-router-vm-YYYYMMDD`）→
自动同步 flake 模块 sha256 并推送。

## 关键设计

- **x86_64 专用**：ARCH 固定在构建脚本内；跨架构映射、binfmt 预检、qemu 注入
  （`lib/arch-detect.sh`）已整体移除。
- **双发行版 musl-openrc**：alpine 与 gentoo 链共用 `base/` 配置体系
  （init.d/conf.d/runlevels），消费端 `os` 选项切换；共享同一 virt 三件套与 initrd。
- **串口控制台（ttyS0/115200）**：getty 常驻 ttyS0——网络故障时的最后恢复通道
  （内核 boot/panic 日志亦输出至此），成本仅一个空闲进程，保留。
- **三件套固定版本**：Alpine 3.24.1 netboot（vmlinuz-virt / initramfs-virt /
  modloop-virt），URL+sha256 在 `image/assemble.sh` 顶部（升级 Alpine 版本时更新）。
- **initrd 注入 ext4 依赖链**：netboot 版 initramfs 不含 ext4（root= 模式不挂
  modloop，官方安装系统的 mkinitfs 会注入——此处为等效操作）；modprobe 读
  `modules.dep.bin` 二进制索引，必须 depmod 重建。
- **uid 0 属主**：CI runner 是 root 直接装配；本地非 root 时 assemble.sh 自动
  fakeroot 包裹（镜像内 /var/empty 等归属错误会导致 sshd 拒启）。
- **无密钥**：不使用 CI secrets——密钥由宿主 deploy 部署时注入（env 文件），
  release 产物公开可下载，密钥绝不进入。
- **配置权威源**：全部路由配置（nftables/dnsmasq/sysctl/服务脚本/网络参数）
  在本仓库 `base/` 与 `network.env`，CI 烙进镜像——出厂即正确；
  deploy 只做密钥注入。
- **无 rootfs 占位符残留**：`network.sh` 构建时按 `network.env` 替换全部
  `__XXX__` 占位符（dnsmasq 主配置/模块配置/nftables vars/tailscale config）。
