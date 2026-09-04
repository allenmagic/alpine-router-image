#!/usr/bin/env bash
# rootfs 装配（须以 root 或 fakeroot 环境执行——tar 内 uid 0 属主必须保留，
# 否则镜像里 /var/empty 归属错误，sshd 的 chroot 目录校验会拒绝启动）
#
# 重构后：不再有 Alpine 三件套（vmlinuz-virt/initrd/modloop）——
# 引导链全部由自建内核 builtin 承担，本脚本只做：
#   rootfs 提取 → 自建内核模块元数据注入 → 引导期模块清单 → getty → ext4
set -euo pipefail

ROOTFS_TARBALL="$1"
OUT_EXT4="$2"
DISTRO="${3:-alpine}"
CUSTOM_MODULES="${4:-}"  # 可选：kernel/out/modules（自建内核的模块元数据树）

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

mkdir -p rootfs
tar xf "$ROOTFS_TARBALL" -C rootfs --numeric-owner

# ============================================================
# 自建内核模块元数据（与 kernel/build.sh 的 modules 目录同源）
# ============================================================
# 全 builtin、0 个 .ko。运行时真正必需的是 modules.builtin.bin——
# modprobe 读它判定「该项是 builtin」返回成功；缺它 /etc/modules 与
# modules-load.d 里的每一项都报
#   FATAL: Module nf_tables not found in directory /lib/modules/<ver>
# 而 openrc 的 modules 服务用 `modprobe -q`（-q 完全吞掉这条错误）且在
# while 管道里丢弃返回码，于是启动日志只有 "Loading modules [ ok ]"，
# 一个字的错误都没有——启动日志检不出来，只能靠 test/verify-guest.sh 在
# guest 内查 /lib/modules/$(uname -r) 与逐项 modprobe。
if [ -n "$CUSTOM_MODULES" ] && [ -d "$CUSTOM_MODULES/lib/modules" ]; then
    for _src in "$CUSTOM_MODULES"/lib/modules/*/; do
        [ -d "$_src" ] || continue
        _ver="$(basename "$_src")"
        mkdir -p "rootfs/lib/modules/$_ver"
        cp -a "$_src." "rootfs/lib/modules/$_ver/"
        echo "[assemble-rootfs] 自建内核元数据: $_ver（$(du -sh "rootfs/lib/modules/$_ver" | cut -f1)，0 个 .ko）"
    done
fi

# 引导期模块加载清单：已移除（全部 builtin，无需 modprobe；元数据
# 完整性由 test/verify-guest.sh 在 guest 内逐项 modprobe 检查）。
# openrc 的 modules 服务保留但清单为空——若元数据目录与 uname -r 不匹配，
# kmod 会尝试真插入并报 "Module already in kernel"（旧清单时代的噪音）。

# 启用 ttyS0 getty（setup.sh 已追加，此 sed 为幂等安全网）
sed -i 's|^#ttyS0:|ttyS0:|' rootfs/etc/inittab

# ============================================================
# mkfs.ext4（512M 稀疏 → qcow2 compact 后 ≈ 实际内容大小）
# rootfs 只读且内容在构建期定型，容量不会运行期增长——512M 约为
# gentoo（双链中较大者）实际占用的 2 倍，留构建余量即可。
# 未来镜像内容增长时调大此行。
# ============================================================
truncate -s 512M "$OUT_EXT4"
mkfs.ext4 -q -F -L "${DISTRO}-rootfs" -d rootfs "$OUT_EXT4"
echo "[assemble-rootfs] 完成"
