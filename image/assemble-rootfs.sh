#!/usr/bin/env bash
# rootfs 装配（须以 root 或 fakeroot 环境执行——tar 内 uid 0 属主必须保留，
# 否则镜像里 /var/empty 归属错误，sshd 的 chroot 目录校验会拒绝启动）
#
# 移植自 qnap-nixos-nas 的 microvm/rootfs-image.nix
set -euo pipefail

ROOTFS_TARBALL="$1"
MODLOOP="$2"
OUT_EXT4="$3"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

mkdir -p rootfs
tar xf "$ROOTFS_TARBALL" -C rootfs --numeric-owner

# 内核模块：modloop-virt 里是 modules/<ver>/（注意非 lib/modules），
# 平移到 rootfs/lib/modules/<ver>，供 openrc/mdev 的 modprobe 使用
mkdir -p rootfs/lib/modules
unsquashfs -d modloop-x "$MODLOOP" >/dev/null
cp -r modloop-x/modules/* rootfs/lib/modules/

# 引导期自动加载：r3s 的 modules 服务注册在 default runlevel，
# 字母序排在 nftables/networking 之后；nf_tables 必须提前就位
cat >> rootfs/etc/modules <<'MODULES'
nf_tables
virtio_net
MODULES

# 启用 ttyS0 getty：r3s 产物默认注释（Alpine 默认状态）。
# vmlinuz-virt 内建 8250 串口驱动，microvm 控制台/串口访问依赖它
sed -i 's|^#ttyS0:|ttyS0:|' rootfs/etc/inittab

truncate -s 8G "$OUT_EXT4"
mkfs.ext4 -q -F -L alpine-rootfs -d rootfs "$OUT_EXT4"
echo "[assemble-rootfs] 完成"
