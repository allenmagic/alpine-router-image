#!/usr/bin/env bash
#
# chroot-helper.sh —— 通用 chroot 挂载/卸载/执行助手
# 可被任意发行版 rootfs 构建脚本 source 复用
#
# 用法：
#   source lib/chroot-helper.sh             # 会自动 source 同目录 arch-detect.sh
#   chroot_enter /path/to/rootfs            # 挂载伪文件系统 + 配置 DNS / qemu
#   chroot_run   /path/to/rootfs /setup.sh  # 在 chroot 内执行命令
#   chroot_exit  /path/to/rootfs            # 卸载（通常由 trap 自动调用）
#
# 设计为可重复 source，不污染调用方的 set 选项。
# 注意：本助手内的 mount 均做容错（失败仅警告、跳过），
#       避免被调用方的 `set -e` 放大成整脚本静默退出。
# 架构识别 / 跨架构判断已抽离至 arch-detect.sh，本文件不再自行判断架构。

# --- 依赖：架构识别函数库（同目录定位，免依赖调用方 CWD）---
_CHROOT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=arch-detect.sh
. "${_CHROOT_LIB_DIR}/arch-detect.sh"

# 需要时挂载的伪文件系统列表（按挂载顺序）
# 说明：不单独挂 dev/pts —— /dev 已整体 --bind（含 pts），
#       在 WSL 等环境单独 bind /dev/pts 常失败且多余。
# shm 单独挂 tmpfs：bind /dev 不包含子挂载点，而 Gentoo 等构建
# （python 的 sem_open 检测）需要 /dev/shm 为 mode=1777 的 tmpfs
_CHROOT_VFS="dev proc sys run shm"

# 状态文件：记录某个 rootfs 实际挂载了哪些点（供逆序卸载）
_chroot_state_file() {
    echo "/tmp/.chroot-mounts-$(echo "$1" | md5sum | cut -d' ' -f1)"
}

# ---------------------------------------------------------------------------
# SETUP（仅在确认跨架构后调用）：注入 qemu-user-static 到 rootfs
#   $1 = rootfs，$2 = 目标架构（aarch64 / x86_64 ...）
# 架构是否跨、binfmt 是否就绪等判断由 arch-detect.sh 提供。
# ---------------------------------------------------------------------------
_chroot_setup_qemu() {
    local rootfs="$1" target="$2"
    local qemu_bin
    qemu_bin="$(arch_qemu_static_name "$target")"

    # binfmt 含 F(fix-binary)：内核已固定解释器，chroot 内无需注入任何 qemu 二进制
    if arch_qemu_binfmt_ready "$target"; then
        echo "  [qemu] binfmt 含 F flag，无需注入 $qemu_bin"
        return 0
    fi

    if command -v "$qemu_bin" >/dev/null 2>&1; then
        cp -f "$(command -v "$qemu_bin")" "$rootfs/usr/bin/" 2>/dev/null || true
        echo "  [qemu] 已注入 $qemu_bin（跨架构 chroot）"
    else
        echo "  [警告] 跨架构 chroot 但未找到 $qemu_bin（若 binfmt 无 F flag 将失败）" >&2
    fi
}

# --- 挂载并进入准备 ---
chroot_enter() {
    local rootfs
    rootfs="$(readlink -f "$1")"
    [ -d "$rootfs" ] || { echo "chroot_enter: 目录不存在 $rootfs" >&2; return 1; }

    local state
    state="$(_chroot_state_file "$rootfs")"
    : > "$state"   # 清空旧状态

    echo "==> chroot_enter: $rootfs"

    local vfs src target opts
    for vfs in $_CHROOT_VFS; do
        target="$rootfs/$vfs"
        mkdir -p "$target"
        # 已挂载则跳过（幂等）
        if mountpoint -q "$target"; then
            continue
        fi
        case "$vfs" in
            dev)   src="/dev";  opts="--bind"  ;;
            proc)  src="proc";  opts="-t proc" ;;
            sys)   src="/sys";  opts="--bind"  ;;
            run)   src="/run";  opts="--bind"  ;;
            shm)   src="shm";   opts="-t tmpfs" ;;
            *)     src="";      opts="--bind"  ;;
        esac

        # —— 关键：挂载失败仅警告并跳过，绝不让 set -e 中止整脚本 ——
        if [ "$opts" = "-t proc" ]; then
            if ! mount -t proc proc "$target" 2>/dev/null; then
                echo "  [警告] 挂载 proc 失败（$target），跳过" >&2
                continue
            fi
        elif [ "$opts" = "-t tmpfs" ]; then
            # /dev/shm：mode=1777，POSIX 信号量（sem_open）依赖
            if ! mount -t tmpfs -o mode=1777 none "$target" 2>/dev/null; then
                echo "  [警告] 挂载 $vfs 失败（tmpfs → $target），跳过" >&2
                continue
            fi
            mount --make-private "$target" 2>/dev/null || true
        else
            if ! mount $opts "$src" "$target" 2>/dev/null; then
                echo "  [警告] 挂载 $vfs 失败（$src → $target），跳过" >&2
                continue
            fi
            # bind mount 设为 private，隔离宿主与 chroot 的挂载传播，
            # 避免 umount 时反向传播导致宿主 /dev/pts 等被意外卸载
            mount --make-private "$target" 2>/dev/null || true
        fi

        # 记录已挂载点（逆序卸载用，故 prepend）
        printf '%s\n' "$target" | cat - "$state" > "$state.tmp" && mv "$state.tmp" "$state"
    done

    # DNS：让 chroot 内可联网
    [ -f /etc/resolv.conf ] && cp -f /etc/resolv.conf "$rootfs/etc/resolv.conf" 2>/dev/null || true

    # 跨架构 qemu：先 check 再 setup —— 架构判断全部委托 arch-detect。
    # 原生架构（如 aarch64 宿主构建 aarch64）arch_need_qemu 返回 1，直接跳过。
    local _host _target
    _host="$(arch_host)"
    _target="$(arch_of_rootfs "$rootfs")"
    if arch_need_qemu "$_host" "$_target"; then
        _chroot_setup_qemu "$rootfs" "$_target"
    else
        echo "  [qemu] 原生架构（$_host），无需 qemu"
    fi

    return 0
}

# --- 在 chroot 内执行命令 ---
# chroot_run <rootfs> <cmd...>   也可传环境变量：用 env 前缀
chroot_run() {
    local rootfs
    rootfs="$(readlink -f "$1")"; shift
    chroot "$rootfs" "$@"
}

# --- 卸载 ---
chroot_exit() {
    local rootfs
    rootfs="$(readlink -f "$1")"
    local state
    state="$(_chroot_state_file "$rootfs")"

    echo "==> chroot_exit: $rootfs"
    if [ -f "$state" ]; then
        # 状态文件已是逆序（最后挂的在最前），逐行卸载
        # 优先用 lazy unmount：立即从命名空间分离，内核后台释放引用，
        # 避免 umount -R 递归卸载时因挂载传播导致宿主 /dev/pts 异常
        while IFS= read -r m; do
            [ -z "$m" ] && continue
            umount -l "$m" 2>/dev/null || umount -R "$m" 2>/dev/null || true
        done < "$state"
        rm -f "$state"
    else
        # 兜底：无状态文件时按已知列表逆序卸载
        local vfs
        for vfs in shm run sys proc dev; do
            umount -l "$rootfs/$vfs" 2>/dev/null || umount -R "$rootfs/$vfs" 2>/dev/null || true
        done
    fi

    # 清理可能注入的 qemu（两种架构都试删，rm -f 不存在也不报错）
    rm -f "$rootfs/usr/bin/qemu-aarch64-static" 2>/dev/null || true
    rm -f "$rootfs/usr/bin/qemu-x86_64-static"  2>/dev/null || true
}

# --- 直接执行（非 source）时提示 ---
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "chroot-helper.sh 是函数库，请用 'source lib/chroot-helper.sh' 复用。" >&2
    exit 0
fi
