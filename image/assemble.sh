#!/usr/bin/env bash
# ============================================================
# 镜像装配：rootfs → 可启动 VM 根磁盘（两件套：kernel + rootfs）
#
# 重构后（剥离 microvm + 单一自建内核）：
#   - 内核由 kernel/build.sh 自建（全 builtin、无 initramfs、MODULES=n），
#     资产 vmlinuz-router 产在 kernel/out/，本脚本不重复处理
#   - 本脚本只做 rootfs：mkfs.ext4 → qcow2
#   - cloud-hypervisor 直接 --kernel + --disk 引导，无 initrd
#
# 用法：
#   ./image/assemble.sh <rootfs-tarball> [output-dir] [distro]
#   产物：<distro>-rootfs.qcow2 / SHA256SUMS
#
# 依赖：e2fsprogs qemu-utils（本地非 root 自动用 fakeroot 包裹装配阶段）
# ============================================================
set -euo pipefail

# 转绝对路径：assemble-rootfs.sh 会 cd 到 mktemp 目录，相对路径会失效
ROOTFS_TARBALL="$(readlink -f "${1:?用法: assemble.sh <rootfs-tarball> [output-dir] [distro]}")"
OUT_DIR="$(readlink -f "${2:-dist}")"
DISTRO="${3:-alpine}"   # rootfs 发行版（决定 rootfs asset 命名）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------- 1. rootfs 装配（须 root/fakeroot：tar 内 uid 0 属主必须保留，
#               否则镜像里 /var/empty 归属错误，sshd 拒绝启动） ----------
echo "[assemble] rootfs：装配 ext4 ..."
if [ "$(id -u)" -eq 0 ]; then
    bash "$SCRIPT_DIR/assemble-rootfs.sh" "$ROOTFS_TARBALL" "$WORK/rootfs.ext4" "$DISTRO"
else
    command -v fakeroot >/dev/null 2>&1 || { echo "[assemble] 非 root 环境需要 fakeroot" >&2; exit 1; }
    fakeroot -- bash "$SCRIPT_DIR/assemble-rootfs.sh" "$ROOTFS_TARBALL" "$WORK/rootfs.ext4" "$DISTRO"
fi

# ---------- 2. qcow2 转换（compact：稀疏 ext4 → 实际内容大小的 qcow2） ----------
echo "[assemble] 转换为 qcow2 ..."
qemu-img convert -f raw -O qcow2 "$WORK/rootfs.ext4" "$WORK/${DISTRO}-rootfs.qcow2"

# ---------- 3. 输出 ----------
cp "$WORK/${DISTRO}-rootfs.qcow2" "$OUT_DIR/"
(cd "$OUT_DIR" && sha256sum "${DISTRO}-rootfs.qcow2" > SHA256SUMS)
echo "[assemble] 完成："
ls -la "$OUT_DIR/"
