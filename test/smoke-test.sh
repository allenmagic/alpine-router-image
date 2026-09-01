#!/usr/bin/env bash
# ============================================================
# 路由 VM 镜像冒烟测试
#
# 下载 microvm-router-image 的 release 资产 → 校验 sha256 → 用
# qemu / cloud-hypervisor 启动并观察串口（ttyS0）。
#
# 用法:
#   test/smoke-test.sh alpine                   # 只测 alpine
#   test/smoke-test.sh gentoo                   # 只测 gentoo
#   test/smoke-test.sh all                      # 两个都测（顺序启动）
#   test/smoke-test.sh alpine --verify-only     # 只下载+校验，不启动
#   test/smoke-test.sh gentoo --backend cloud-hypervisor
#
#   # 用 release 里的自建内核（全 builtin）测同一批 rootfs
#   test/smoke-test.sh alpine --kernel router
#   test/smoke-test.sh alpine --kernel router --no-initrd   # 连空占位也不传
#
# 选项:
#   --tag TAG         release tag（默认自动探测 GitHub 最新）
#   --backend NAME    qemu | cloud-hypervisor（默认 qemu）
#   --kernel VARIANT  virt | router（默认 virt），对应 router.nix 的
#                     microvm.router.kernel。两者都从同一 release 下载并校验：
#                       virt   → vmlinuz-virt   + initrd（10.3M，注入 ext4 依赖链）
#                       router → vmlinuz-router + initramfs-empty.gz（50 字节占位）
#   --no-initrd       不传 initrd。router 变体全 builtin，占位 initramfs 只为满足
#                     microvm.nix 的无条件 --initramfs；本地可直接省掉它
#   --assert          tee 启动日志并断言：FATAL: Module / Function not
#                     implemented / hwclock: / Kernel panic 一律视为失败
#                     （内核能启动 ≠ 能力完整；openrc 的 modules 服务结构上
#                     无法失败，日志是唯一能拦住静默丢失的地方）
#   --assets-dir DIR  资产缓存目录（默认 <仓库>/build/smoke-assets，已被 .gitignore 忽略）
#   --no-download     跳过下载，只用缓存里已有的文件
#   --force-download  无条件重新下载（默认已会按 sha256 自动刷新过期缓存）
#   --verify-only     只下载 + 校验 sha256，不启动
#   --loglevel N      追加内核参数 loglevel=N（0-7，默认不追加；3 可屏蔽 nft warn 级日志对串口的干扰）
#   --proxy           下载走 proxychains 代理（默认 auto：装了 proxychains 就自动用）
#   --no-proxy        强制直连，不走代理
#   -h|--help         本帮助
#
# 依赖: curl sha256sum python3（探测/解析 JSON）。
#   启动需要 qemu-system-x86_64 或 cloud-hypervisor（--verify-only 不需要）。
#   登录串口: 用户 root / 密码 root（CI 镜像默认 ROOT_PASSWORD=root）。
# ============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_SLUG="allenmagic/microvm-router-image"   # 用 --repo 覆盖（fork 时）
TAG=""                                        # 空 = 自动探测
BACKEND="qemu"
ASSETS_DIR="${REPO_ROOT}/build/smoke-assets"
DO_DOWNLOAD=1
FORCE_DOWNLOAD=0   # --force-download：无条件重新下载（默认按 sha256 自动刷新）
VERIFY_ONLY=0
LOGLEVEL=""      # 空 = 不追加 loglevel；如 --loglevel 3
PROXY_MODE="auto"   # auto | on | off（下载是否走 proxychains）
PROXY=""            # 实际前缀命令（resolve 后，空 = 直连）
DISTRO=""
KERNEL="virt"       # --kernel：内核变体 virt | router（都从 release 取）
USE_INITRD=1        # --no-initrd：置 0（router 全 builtin，占位 initramfs 可省）
ASSERT=0            # --assert：tee 启动日志并断言（无 FATAL/ENOSYS/panic 等）

usage() {
    sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

log() { printf '[smoke] %s\n' "$*" >&2; }
die() { printf '[smoke] 错误: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --tag)        TAG="${2:?--tag 需要值}"; shift 2 ;;
        --backend)    BACKEND="${2:?--backend 需要值}"; shift 2 ;;
        --assets-dir) ASSETS_DIR="${2:?--assets-dir 需要值}"; shift 2 ;;
        --repo)       REPO_SLUG="${2:?--repo 需要值}"; shift 2 ;;
        --no-download) DO_DOWNLOAD=0; shift ;;
        --force-download) FORCE_DOWNLOAD=1; shift ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        --loglevel)    LOGLEVEL="${2:?--loglevel 需要值(0-7)}"; shift 2 ;;
        --kernel)      KERNEL="${2:?--kernel 需要值(virt|router)}"; shift 2 ;;
        --no-initrd)   USE_INITRD=0; shift ;;
        --assert)      ASSERT=1; shift ;;
        --proxy)       PROXY_MODE="on"; shift ;;
        --no-proxy)    PROXY_MODE="off"; shift ;;
        alpine|gentoo|all) DISTRO="$1"; shift ;;
        *) die "未知参数: $1（见 --help）" ;;
    esac
done

[ -n "$DISTRO" ] || die "缺少发行版参数（alpine|gentoo|all），见 --help"

case "$BACKEND" in
    qemu|cloud-hypervisor) ;;
    *) die "未知后端: $BACKEND（支持 qemu | cloud-hypervisor）" ;;
esac

# 内核变体 → release 资产名。与 nixos-modules/router.nix 的 kernelVariants
# 一一对应，改那边要同步改这里（资产名不带版本号，故 LTS point release bump
# 不影响本表）。
case "$KERNEL" in
    virt)   KERNEL_ASSET="vmlinuz-virt";   INITRD_ASSET="initrd" ;;
    router) KERNEL_ASSET="vmlinuz-router"; INITRD_ASSET="initramfs-empty.gz" ;;
    *) die "未知内核变体: $KERNEL（支持 virt | router）" ;;
esac

mkdir -p "$ASSETS_DIR"

# 代理解析：默认 auto（装了 proxychains 就用于下载），--proxy 强制、--no-proxy 直连
detect_proxy() {
    command -v proxychains4 >/dev/null 2>&1 && { PROXY="proxychains4"; return 0; }
    command -v proxychains  >/dev/null 2>&1 && { PROXY="proxychains";  return 0; }
    return 1
}
case "$PROXY_MODE" in
    on)   detect_proxy || die "未找到 proxychains（Arch: sudo pacman -S proxychains-ng）" ;;
    off)  PROXY="" ;;
    auto) detect_proxy || PROXY="" ;;
esac
[ -n "$PROXY" ] && log "下载走代理: $PROXY"

# 内核 cmdline：--loglevel 可选追加，用于压掉 nft warn 级日志对串口的干扰
KCMD="console=ttyS0 root=/dev/vda rootfstype=ext4 rw"
[ -n "$LOGLEVEL" ] && KCMD="${KCMD} loglevel=${LOGLEVEL}"

# ------------------------------------------------------------
# 探测最新 release tag（无 --tag 时）
# ------------------------------------------------------------
latest_tag() {
    local url="https://api.github.com/repos/${REPO_SLUG}/releases/latest"
    $PROXY python3 - "$url" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "smoke-test"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        print(json.load(r).get("tag_name", ""))
except Exception as e:
    print("", file=sys.stderr)
    sys.exit(1)
PY
}

if [ -z "$TAG" ]; then
    log "探测最新 release tag ..."
    TAG="$(latest_tag)" || die "探测失败，请用 --tag 显式指定"
    [ -n "$TAG" ] || die "未取到 tag_name，请用 --tag 显式指定"
fi
BASE="https://github.com/${REPO_SLUG}/releases/download/${TAG}"
log "release: ${TAG}（${BASE}）"

# ------------------------------------------------------------
# 下载与校验
# ------------------------------------------------------------
fetch() {
    local url="$1" out="$2"
    log "下载 ${url##*/} ..."
    $PROXY curl -sSLf --retry 3 -o "$out" "$url" || die "下载失败: $url"
}

# SHA256SUMS 路径（判断缓存是否最新的依据）
SUMS="${ASSETS_DIR}/SHA256SUMS"

# 校验：SHA256SUMS 里 initrd/vmlinuz-virt 因双发行版各写一次而存在重复条目，
# 且 initrd 两条哈希不同（gzip 未加 -n 烙了时间戳）——所以判定规则是
# 「命中同名文件下的任意一条」即可，而不是 sha256sum -c 的严格一一对应。
# 返回 0 = 缓存文件的 sha256 命中（已是最新），非 0 = 缺失或过期。
_is_current() {
    local f="$1" h
    [ -f "${ASSETS_DIR}/${f}" ] || return 1
    h="$(sha256sum "${ASSETS_DIR}/${f}" | awk '{print $1}')"
    awk -v n="$f" -v h="$h" '$2==n && $1==h {found=1} END{exit !found}' "$SUMS"
}

# 本次真正要用到的 release 资产。内核/initrd 按 --kernel 变体取名，两个变体
# 都走同一套下载+校验；--no-initrd 时 initramfs 既不下载也不校验。
_asset_list() {
    local distro="$1"
    printf '%s\n' "$KERNEL_ASSET"
    [ "$USE_INITRD" = 0 ] || printf '%s\n' "$INITRD_ASSET"
    printf '%s-rootfs.qcow2\n' "$distro"
}

verify() {
    local distro="$1"
    # 始终拉最新 SHA256SUMS，确保校验针对最新 release（而非缓存里的旧 sums）
    fetch "$BASE/SHA256SUMS" "$SUMS"

    local f
    while read -r f; do
        [ -f "${ASSETS_DIR}/${f}" ] || die "缺失 ${ASSETS_DIR}/${f}（去掉 --no-download 或先下载）"
        if _is_current "$f"; then
            log "  ✓ ${f}"
        else
            die "  ✗ ${f}: 校验失败（sha256 不在 release SHA256SUMS 中）"
        fi
    done < <(_asset_list "$distro")

    log "  · 内核变体: ${KERNEL}（${KERNEL_ASSET}）"
    [ "$USE_INITRD" = 0 ] && log "  ~ 不使用 initrd（内核需 ext4/virtio 全 builtin）"
    return 0
}

download() {
    local distro="$1"
    # 始终拉最新 SHA256SUMS（很小），作为判断缓存是否最新的唯一依据
    fetch "$BASE/SHA256SUMS" "$SUMS"

    local f
    while read -r f; do
        if [ "$FORCE_DOWNLOAD" = 1 ]; then
            fetch "$BASE/$f" "${ASSETS_DIR}/${f}"
        elif _is_current "$f"; then
            log "已是最新 ${f}，跳过下载"
        else
            [ -f "${ASSETS_DIR}/${f}" ] && log "缓存过期 ${f}，重新下载"
            fetch "$BASE/$f" "${ASSETS_DIR}/${f}"
        fi
    done < <(_asset_list "$distro")
}

# ------------------------------------------------------------
# 启动（前台，串口直连）
# ------------------------------------------------------------
# 内核与 initrd 的实际取值（--kernel 变体 / --no-initrd 的落点）
_kernel_path() { printf '%s' "${ASSETS_DIR}/${KERNEL_ASSET}"; }
_initrd_path() { printf '%s' "${ASSETS_DIR}/${INITRD_ASSET}"; }

# ------------------------------------------------------------
# 启动日志断言
# ------------------------------------------------------------
# 为什么需要：内核能编译、能启动、服务全 [ ok ]，仍可能静默丢失能力。
# 实测踩过三次，全部因为 allnoconfig 把带 prompt 的符号一律置 n（即使
# Kconfig 写着 default y），而 verify-config.py 只能校验声明过的项：
#   FILE_LOCKING 丢 → openrc 启动时 flock 全部 "Function not implemented"
#   SECCOMP 丢     → sshd 每次连接的 privsep 子进程被自己的沙箱打死
#   RTC_INTF_DEV 丢 → 驱动已绑定但 /dev/rtc0 不存在，hwclock 失败
# 更麻烦的是 openrc 的 modules 服务用 `modprobe -q` 且在 while 管道里丢弃
# 返回码——它结构上无法失败，九个模块全 FATAL 也照样打印 [ ok ]。
# 所以唯一能拦住这类问题的地方是启动日志本身。
_assert_log() {
    local log_file="$1" distro="$2" fails=0
    # ANSI 转义会打断 grep 的模式匹配
    local plain; plain="$(mktemp)"
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$log_file" > "$plain"

    _expect_absent() {
        local pat="$1" why="$2" n
        n="$(grep -ac "$pat" "$plain" || true)"
        if [ "$n" -gt 0 ]; then
            log "  ✗ 出现 ${n} 次「${pat}」—— ${why}"
            grep -a "$pat" "$plain" | head -3 | sed 's/^/      /' >&2
            fails=$((fails + 1))
        else
            log "  ✓ 无「${pat}」"
        fi
    }

    log "启动日志断言（${distro}）..."
    # 注：openrc 的 modules 服务用 `modprobe -q`，-q 会完全吞掉
    # "FATAL: Module xxx not found" —— 启动期九次失败在日志里一个字都没有，
    # 只有 "Loading modules [ ok ]"。所以模块元数据缺失**无法从启动日志检出**，
    # 只能靠 test/verify-guest.sh 在 guest 内查 /lib/modules/$(uname -r)。
    # 这里保留该模式仅为捕获非 -q 调用方（如手工 modprobe、其他服务）的失败。
    _expect_absent 'FATAL: Module'          '有模块名解析失败（非 -q 调用方）'
    _expect_absent 'Function not implemented' '内核缺 syscall（如 CONFIG_FILE_LOCKING 未开）'
    _expect_absent 'hwclock:'                'RTC 不可用（缺 RTC_CLASS/RTC_DRV_CMOS/RTC_INTF_DEV）'
    _expect_absent 'Kernel panic'            '内核 panic'
    _expect_absent 'Unable to mount root'    '根盘挂载失败（virtio_blk/ext4 未 builtin 且无 initrd）'

    # 正向断言：必须真的走完启动
    if grep -aq 'login:' "$plain"; then
        log "  ✓ 到达登录提示"
    else
        log "  ✗ 未到达登录提示（启动未完成）"
        fails=$((fails + 1))
    fi

    rm -f "$plain"
    [ "$fails" -eq 0 ] || return 1
}

boot_qemu() {
    local distro="$1"
    command -v qemu-system-x86_64 >/dev/null 2>&1 || \
        die "未找到 qemu-system-x86_64（Arch: sudo pacman -S qemu-base）"
    local initrd_args=()
    [ "$USE_INITRD" = 1 ] && initrd_args=(-initrd "$(_initrd_path)")
    log "qemu 启动 ${distro}（串口直连 ttyS0；退出按 Ctrl-A 然后 X）"
    qemu-system-x86_64 -m 512 -smp 2 \
        -kernel "$(_kernel_path)" \
        "${initrd_args[@]}" \
        -append "$KCMD" \
        -snapshot \
        -drive "file=${ASSETS_DIR}/${distro}-rootfs.qcow2,format=qcow2,if=virtio" \
        -netdev user,id=wan -device virtio-net-pci,netdev=wan,mac=02:00:00:01:00:01 \
        -netdev user,id=lan -device virtio-net-pci,netdev=lan,mac=02:00:00:01:00:02 \
        -nographic
}

boot_ch() {
    local distro="$1"
    # AUR 的 cloud-hypervisor-bin 只装 cloud-hypervisor-static（无 cloud-hypervisor 主名）
    local ch; ch="$(command -v cloud-hypervisor 2>/dev/null || command -v cloud-hypervisor-static 2>/dev/null)"
    [ -n "$ch" ] || die "未找到 cloud-hypervisor（Arch AUR: paru -S cloud-hypervisor-bin）"
    # CH 无 qemu 的 -snapshot 等价物，先复制到临时文件再启动，避免污染缓存镜像
    # （与生产 disk-prep 先复制到状态盘同一思路）
    local img="${ASSETS_DIR}/${distro}-rootfs.qcow2"
    local scratch; scratch="$(mktemp --suffix=.qcow2)" || die "创建临时镜像失败"
    log "复制镜像到临时文件（避免污染缓存）..."
    cp "$img" "$scratch"
    local initramfs_args=()
    [ "$USE_INITRD" = 1 ] && initramfs_args=(--initramfs "$(_initrd_path)")
    log "cloud-hypervisor 启动 ${distro}（纯 boot 冒烟，未接 tap；Ctrl+C 退出）"
    sudo "$ch" \
        --kernel "$(_kernel_path)" \
        "${initramfs_args[@]}" \
        --cmdline "$KCMD" \
        --disk "path=$scratch" \
        --cpus boot=2 \
        --memory size=512M \
        --serial tty --console off
    local rc=$?
    rm -f "$scratch"
    return $rc
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
main() {
    local distros
    if [ "$DISTRO" = "all" ]; then distros="alpine gentoo"; else distros="$DISTRO"; fi

    # 阶段一：下载 + 校验（三件套共用，只下一次）
    for d in $distros; do
        [ "$DO_DOWNLOAD" = 1 ] && download "$d"
        log "校验 ${d} 资产 ..."
        verify "$d"
    done

    [ "$VERIFY_ONLY" = 1 ] && { log "校验全部通过，跳过启动。"; exit 0; }

    # 阶段二：逐个启动
    local assert_fails=0
    for d in $distros; do
        log "========== 启动 ${d}（登录 root/root；验证 rc-status、nft list ruleset）=========="
        set +e
        if [ "$ASSERT" = 1 ]; then
            # tee 留一份日志供断言；串口仍直连终端，交互不受影响
            local blog="${ASSETS_DIR}/boot-${d}.log"
            "boot_${BACKEND}" "$d" 2>&1 | tee "$blog"
            local rc=${PIPESTATUS[0]}
        else
            "boot_${BACKEND}" "$d"
            local rc=$?
        fi
        set -e
        log "${d} 退出（rc=$rc）"
        [ "$rc" -eq 0 ] || log "提示: rc=$rc 可能是 qemu Ctrl-A X / CH Ctrl+C 的正常退出，非镜像问题。"

        if [ "$ASSERT" = 1 ]; then
            set +e
            _assert_log "$blog" "$d"
            local arc=$?
            set -e
            [ "$arc" -eq 0 ] || assert_fails=$((assert_fails + 1))
            log "启动日志: ${blog#$REPO_ROOT/}"
        fi
    done

    if [ "$assert_fails" -gt 0 ]; then
        die "${assert_fails} 个发行版的启动日志断言未通过"
    fi
}

main "$@"
