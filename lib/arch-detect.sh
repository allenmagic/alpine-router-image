#!/usr/bin/env bash
#
# arch-detect.sh —— 构建主机 / 目标 rootfs 架构识别与跨架构判断
# 纯函数库，被各发行版 build.sh 与 chroot-helper.sh source 复用。
#
# 用法：
#   source lib/arch-detect.sh
#   host="$(arch_host)"                      # → aarch64 / x86_64
#   target="$(arch_of_rootfs "$ROOTFS")"     # → aarch64 / x86_64 / ""(未知)
#   if arch_need_qemu "$host" "$target"; then ... ; fi
#   arch_precheck "$ROOTFS"                   # 一站式预检 + 友好输出
#
# 设计为可重复 source，不污染调用方的 set 选项。

# --- 架构别名归一化 ---
arch_normalize() {
    case "$1" in
        arm64|aarch64)              echo "aarch64" ;;
        amd64|x86_64|x86-64|x64)    echo "x86_64"  ;;
        armv7l|armhf|arm)           echo "armhf"   ;;
        riscv64|riscv)              echo "riscv64" ;;
        *)                          echo "$1"      ;;
    esac
}

# --- 构建主机架构（归一化后）---
arch_host() {
    arch_normalize "$(uname -m)"
}

# --- 从 rootfs 内一个 ELF 探测目标架构；探测不到回传空串 ---
arch_of_rootfs() {
    local rootfs="$1" sample raw
    sample="$(find "$rootfs"/bin "$rootfs"/usr/bin -maxdepth 1 -type f 2>/dev/null | head -n1)"
    [ -z "$sample" ] && { echo ""; return 0; }

    raw="$(file -b "$sample" 2>/dev/null || true)"
    case "$raw" in
        *aarch64*)        echo "aarch64" ;;
        *x86-64*)         echo "x86_64"  ;;
        *"ARM,"*|*ARM\ *) echo "armhf"   ;;
        *RISC-V*)         echo "riscv64" ;;
        *)                echo ""        ;;
    esac
}

# --- qemu-user-static 二进制名 ---
arch_qemu_static_name() {
    echo "qemu-$(arch_normalize "$1")-static"
}

# --- binfmt 是否已注册且含 F(fix-binary) flag ---
#   含 F：内核已固定解释器，chroot 内无需注入 qemu 二进制
arch_qemu_binfmt_ready() {
    local arch
    arch="$(arch_normalize "$1")"
    grep -q 'flags:.*F' "/proc/sys/fs/binfmt_misc/qemu-${arch}" 2>/dev/null
}

# --- 是否需要跨架构 qemu ---
#   $1=host $2=target
#   return 0 = 需要（host≠target 且 target 已知）
#   return 1 = 原生 / 目标未知（保守当原生，不瞎注入）
arch_need_qemu() {
    local host target
    host="$(arch_normalize "$1")"
    target="$(arch_normalize "$2")"
    [ -z "$target" ] && return 1
    [ "$host" != "$target" ] && return 0
    return 1
}

# --- 一站式预检：打印结论，便于各 build.sh 复用 ---
#   $1 = rootfs（可选；不传则只报宿主架构）
#   返回 0 = 可继续构建；非 0 = 缺 qemu 等致命问题
arch_precheck() {
    local rootfs="${1:-}" host target
    host="$(arch_host)"

    if [ -z "$rootfs" ] || [ ! -d "$rootfs" ]; then
        echo "[arch] 构建主机架构：$host"
        return 0
    fi

    target="$(arch_of_rootfs "$rootfs")"
    if [ -z "$target" ]; then
        echo "[arch] 构建主机：$host；目标架构未知（rootfs 尚无 ELF），按原生处理"
        return 0
    fi

    if arch_need_qemu "$host" "$target"; then
        if arch_qemu_binfmt_ready "$target"; then
            echo "[arch] 跨架构：$host → $target（binfmt 含 F flag，无需注入 qemu）"
            return 0
        fi
        if command -v "$(arch_qemu_static_name "$target")" >/dev/null 2>&1; then
            echo "[arch] 跨架构：$host → $target（将注入 $(arch_qemu_static_name "$target")）"
            return 0
        fi
        echo "[arch][错误] 跨架构 $host → $target，但缺少 $(arch_qemu_static_name "$target") 且 binfmt 无 F flag" >&2
        return 1
    fi

    echo "[arch] 原生架构：$host == $target，无需 qemu"
    return 0
}


# ---------------------------------------------------------------------------
# 为给定目标架构选择合适的 strip 命令。
#   $1 = 目标架构（aarch64 / x86_64 ...，通常来自 arch_of_rootfs）
# 选择逻辑：
#   - 宿主 == 目标：本机 strip 即可真正生效
#   - 跨架构：优先交叉 strip（<target>-linux-gnu-strip），其次 llvm-strip（全架构），
#             都没有则退回本机 strip（但对异架构 ELF 不会真正生效，调用方应提示）
# 通过 stdout 回传 strip 命令名；找不到任何可用 strip 时回传 "strip" 兜底。
# ---------------------------------------------------------------------------
arch_strip_cmd() {
    local target host cross
    target="$(arch_normalize "$1")"
    host="$(arch_host)"

    # 原生：本机 strip 直接可用
    if [ "$host" = "$target" ]; then
        echo "strip"
        return 0
    fi

    # 跨架构：优先交叉 strip
    case "$target" in
        aarch64) cross="aarch64-linux-gnu-strip" ;;
        x86_64)  cross="x86_64-linux-gnu-strip"  ;;
        armhf)   cross="arm-linux-gnueabihf-strip" ;;
        riscv64) cross="riscv64-linux-gnu-strip" ;;
        *)       cross="" ;;
    esac

    if [ -n "$cross" ] && command -v "$cross" >/dev/null 2>&1; then
        echo "$cross"; return 0
    fi
    if command -v llvm-strip >/dev/null 2>&1; then
        echo "llvm-strip"; return 0
    fi
    echo "strip"   # 兜底（异架构下可能不生效，调用方负责提示）
    return 0
}

# 判断给定 strip 命令对目标架构是否"真正有效"
#   $1=strip命令 $2=目标架构
#   return 0 = 有效；return 1 = 可能无效（本机 strip 处理异架构 ELF）
arch_strip_effective() {
    local strip="$1" target host
    target="$(arch_normalize "$2")"
    host="$(arch_host)"
    [ "$host" = "$target" ] && return 0          # 原生，必然有效
    [ "$strip" = "strip" ] && return 1           # 跨架构却用本机 strip → 可能无效
    return 0                                      # 交叉 strip / llvm-strip → 有效
}



# ---------------------------------------------------------------------------
# 直接执行（非 source）时：跑一次自检并打印用法，方便手动验证
#   被 source 时这段不会触发，不污染调用方。
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "arch-detect.sh —— 架构识别函数库（应被 source，而非直接执行）"
    echo
    echo "自检："
    echo "  构建主机架构：$(arch_host)"

    # 若命令行带了一个 rootfs 路径参数，顺便对它做预检
    if [ -n "${1:-}" ]; then
        echo "  目标 rootfs ：$1"
        echo
        arch_precheck "$1"
    else
        echo
        echo "用法："
        echo "  source lib/arch-detect.sh        # 在脚本中复用函数"
        echo "  bash   lib/arch-detect.sh <rootfs>   # 手动对某 rootfs 预检"
        echo
        echo "可用函数：arch_host / arch_normalize / arch_of_rootfs /"
        echo "          arch_need_qemu / arch_qemu_binfmt_ready / arch_precheck"
    fi
fi
