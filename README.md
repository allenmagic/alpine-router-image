# alpine-router-image

Alpine 路由 VM 镜像生产仓库：CI 构建 Alpine rootfs（构建链移植自
[nanopi-r3s-rootfs](https://github.com/allenmagic/nanopi-r3s-rootfs)，单一发行版链）
+ 装配 Alpine 官方 virt 三件套，产出可启动的 VM 镜像 release asset，
供 [qnap-nixos-nas](https://github.com/allenmagic/qnap-nixos-nas) 的 microvm 直接拉取启动。

## 供应链分工

| repo | 职责 |
|---|---|
| 本仓库 | VM 镜像生产：rootfs 构建 + virt 三件套装配 → release |
| qnap-nixos-nas | microvm 声明 + fetchurl 拉镜像 + deploy（配置/密钥唯一覆盖通道） |
| nanopi-r3s-rootfs | R3S 路由器 rootfs（多发行版框架，本仓库的一次性移植来源） |

## 构建流程

```bash
# 1. 构建 Alpine rootfs（产物 build/alpine/alpine-rootfs-minimal.tar.xz）
ARCH=x86_64 PACK=1 sudo -E bash alpine/build.sh

# 2. 装配 VM 镜像（下载官方三件套 + initrd 注入 ext4 + rootfs 装配 + qcow2）
./image/assemble.sh build/alpine/alpine-rootfs-minimal.tar.xz dist
# 产物：dist/{vmlinuz-virt, initrd, alpine-router-rootfs.qcow2, SHA256SUMS}
```

CI 手动触发后上传 release（tag `alpine-router-image-YYYYMMDD`）。

## 关键设计

- **三件套固定版本**：Alpine 3.24.1 netboot（vmlinuz-virt / initramfs-virt /
  modloop-virt），URL+sha256 在 `image/assemble.sh` 顶部，与 qnap-nixos-nas
  的 microvm/*.nix 保持一致（升级 Alpine 版本时两边同步）。
- **initrd 注入 ext4 依赖链**：netboot 版 initramfs 不含 ext4（root= 模式不挂
  modloop，官方安装系统的 mkinitfs 会注入——此处为等效操作）；modprobe 读
  `modules.dep.bin` 二进制索引，必须 depmod 重建。
- **uid 0 属主**：CI runner 是 root 直接装配；本地非 root 时 assemble.sh 自动
  fakeroot 包裹（镜像内 /var/empty 等归属错误会导致 sshd 拒启）。
- **无密钥**：不使用 CI secrets——密钥由宿主 deploy 部署时注入，release 产物
  公开可下载，密钥绝不进入。
- **出厂配置会被覆盖**：rootfs 烙入的配置（r3s 版）在部署时被 NAS 权威版
  （alpine-router/base）覆盖，deploy 是唯一配置覆盖通道。
