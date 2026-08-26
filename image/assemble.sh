#!/usr/bin/env bash
# ============================================================
# 镜像装配：Alpine 官方 virt 三件套 + rootfs → 可启动 VM 镜像
#
# 逻辑移植自 qnap-nixos-nas 的 microvm/{kernel,initrd,rootfs-image}.nix：
#   - initramfs-virt 注入 ext4 依赖链（netboot 版不含 ext4，
#     root= 模式不挂 modloop；modprobe 读 modules.dep.bin 必须 depmod 重建）
#   - rootfs 注入 modloop 模块（与 vmlinuz-virt 精确配套）+ 引导模块 + ttyS0 getty
#   - 8G ext4 → qcow2（compact：release 体积 ≈ 实际内容，宿主侧 autoCreate 复制快）
#
# 用法：
#   ./image/assemble.sh <rootfs-tarball> [output-dir]
#   产物：vmlinuz-virt / initrd / alpine-router-rootfs.qcow2 / SHA256SUMS
#
# 依赖：wget cpio gzip squashfs-tools kmod e2fsprogs qemu-utils
#       CI runner 是 root 直接跑；本地非 root 自动用 fakeroot 包裹装配阶段
# ============================================================
set -euo pipefail

ALPINE_VERSION="3.24.1"
NETBOOT_BASE="https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/netboot-${ALPINE_VERSION}"

# 与 qnap-nixos-nas 的 microvm/*.nix 一致（Alpine 官方文件，固定版本）
VMLINUZ_SHA256="1e6bf9027720c75c3ed0d79171f21b5791ee40ca9795d07c7c6e04dc5ea2ae90"
INITRAMFS_SHA256="6d80a739fedeeb6cd63e24dd208845e22199c41a5fb2054941ef61ec30264fa9"
MODLOOP_SHA256="78907e7cc812d555f08d4e1133d090cf11fa197370882adfe67b0a5986ccb3f9"

# 转绝对路径：assemble-rootfs.sh 会 cd 到 mktemp 目录，相对路径会失效
ROOTFS_TARBALL="$(readlink -f "${1:?用法: assemble.sh <rootfs-tarball> [output-dir]}")"
OUT_DIR="$(readlink -f "${2:-dist}")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------- 1. 下载三件套并校验 ----------
_fetch() {
    _url="$1"; _sha="$2"; _out="$3"
    echo "[assemble] 下载 ${_out} ..."
    wget -q -O "$WORK/$_out" "$_url"
    echo "${_sha}  $WORK/$_out" | sha256sum -c -
}

_fetch "$NETBOOT_BASE/vmlinuz-virt" "$VMLINUZ_SHA256" vmlinuz-virt
_fetch "$NETBOOT_BASE/initramfs-virt" "$INITRAMFS_SHA256" initramfs-virt
_fetch "$NETBOOT_BASE/modloop-virt" "$MODLOOP_SHA256" modloop-virt

# ---------- 2. initrd 装配：注入 ext4 依赖链 ----------
echo "[assemble] initrd：注入 ext4 依赖链（crc16/mbcache/jbd2/ext4）+ depmod ..."
mkdir -p "$WORK/initrd-x" "$WORK/modloop-x"
zcat "$WORK/initramfs-virt" | (cd "$WORK/initrd-x" && cpio -id 2>/dev/null)
unsquashfs -d "$WORK/modloop-x" "$WORK/modloop-virt" >/dev/null
MV="$(ls "$WORK/modloop-x/modules/" | grep -E '^[0-9]')"
D="$WORK/initrd-x/lib/modules/$MV/kernel"
mkdir -p "$D/fs/ext4" "$D/fs/jbd2" "$D/lib"
cp "$WORK/modloop-x/modules/$MV/kernel/fs/ext4/ext4.ko" "$D/fs/ext4/"
cp "$WORK/modloop-x/modules/$MV/kernel/fs/jbd2/jbd2.ko" "$D/fs/jbd2/"
cp "$WORK/modloop-x/modules/$MV/kernel/fs/mbcache.ko" "$D/fs/"
cp "$WORK/modloop-x/modules/$MV/kernel/lib/crc/crc16.ko" "$D/lib/"
depmod -b "$WORK/initrd-x" "$MV"
(cd "$WORK/initrd-x" && find . -print0 | cpio --null -o --format=newc | gzip -9 > "$WORK/initrd")

# ---------- 3. rootfs 装配 ----------
echo "[assemble] rootfs：注入 modloop 模块 + 装配 ext4 ..."
if [ "$(id -u)" -eq 0 ]; then
    bash "$SCRIPT_DIR/assemble-rootfs.sh" "$ROOTFS_TARBALL" "$WORK/modloop-virt" "$WORK/rootfs.ext4"
else
    command -v fakeroot >/dev/null 2>&1 || { echo "[assemble] 非 root 环境需要 fakeroot" >&2; exit 1; }
    fakeroot -- bash "$SCRIPT_DIR/assemble-rootfs.sh" "$ROOTFS_TARBALL" "$WORK/modloop-virt" "$WORK/rootfs.ext4"
fi

# ---------- 4. qcow2 转换（compact：稀疏 ext4 → 实际内容大小的 qcow2） ----------
echo "[assemble] 转换为 qcow2 ..."
qemu-img convert -f raw -O qcow2 "$WORK/rootfs.ext4" "$WORK/alpine-router-rootfs.qcow2"

# ---------- 5. 输出 ----------
cp "$WORK/vmlinuz-virt" "$WORK/initrd" "$WORK/alpine-router-rootfs.qcow2" "$OUT_DIR/"
(cd "$OUT_DIR" && sha256sum vmlinuz-virt initrd alpine-router-rootfs.qcow2 > SHA256SUMS)
echo "[assemble] 完成："
ls -la "$OUT_DIR/"
