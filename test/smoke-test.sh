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
# 选项:
#   --tag TAG         release tag（默认自动探测 GitHub 最新）
#   --backend NAME    qemu | cloud-hypervisor（默认 qemu）
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

verify() {
    local distro="$1"
    if [ "$FORCE_DOWNLOAD" = 1 ] || [ ! -f "$SUMS" ]; then
        fetch "$BASE/SHA256SUMS" "$SUMS"
    fi

    local f
    for f in vmlinuz-virt initrd "${distro}-rootfs.qcow2"; do
        [ -f "${ASSETS_DIR}/${f}" ] || die "缺失 ${ASSETS_DIR}/${f}（去掉 --no-download 或先下载）"
        if _is_current "$f"; then
            log "  ✓ ${f}"
        else
            die "  ✗ ${f}: 校验失败（sha256 不在 release SHA256SUMS 中）"
        fi
    done
}

download() {
    local distro="$1"
    # 先拉 SHA256SUMS，用它判断缓存是否已是最新（避免重复下载过期/已是最新的文件）
    if [ "$FORCE_DOWNLOAD" = 1 ] || [ ! -f "$SUMS" ]; then
        fetch "$BASE/SHA256SUMS" "$SUMS"
    fi

    local f
    for f in vmlinuz-virt initrd "${distro}-rootfs.qcow2"; do
        if [ "$FORCE_DOWNLOAD" = 1 ]; then
            fetch "$BASE/$f" "${ASSETS_DIR}/${f}"
        elif _is_current "$f"; then
            log "已是最新 ${f}，跳过下载"
        else
            [ -f "${ASSETS_DIR}/${f}" ] && log "缓存过期 ${f}，重新下载"
            fetch "$BASE/$f" "${ASSETS_DIR}/${f}"
        fi
    done
}

# ------------------------------------------------------------
# 启动（前台，串口直连）
# ------------------------------------------------------------
boot_qemu() {
    local distro="$1"
    command -v qemu-system-x86_64 >/dev/null 2>&1 || \
        die "未找到 qemu-system-x86_64（Arch: sudo pacman -S qemu-base）"
    log "qemu 启动 ${distro}（串口直连 ttyS0；退出按 Ctrl-A 然后 X）"
    qemu-system-x86_64 -m 512 -smp 2 \
        -kernel "${ASSETS_DIR}/vmlinuz-virt" \
        -initrd "${ASSETS_DIR}/initrd" \
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
    log "cloud-hypervisor 启动 ${distro}（纯 boot 冒烟，未接 tap；Ctrl+C 退出）"
    sudo "$ch" \
        --kernel "${ASSETS_DIR}/vmlinuz-virt" \
        --initramfs "${ASSETS_DIR}/initrd" \
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
    for d in $distros; do
        log "========== 启动 ${d}（登录 root/root；验证 rc-status、nft list ruleset）=========="
        set +e
        "boot_${BACKEND}" "$d"
        local rc=$?
        set -e
        log "${d} 退出（rc=$rc）"
        [ "$rc" -eq 0 ] || log "提示: rc=$rc 可能是 qemu Ctrl-A X / CH Ctrl+C 的正常退出，非镜像问题。"
    done
}

main "$@"
