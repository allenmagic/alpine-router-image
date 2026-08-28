#!/usr/bin/env bash
# ============================================================
# 路由 VM 实际环境测试（cloud-hypervisor + 真实 tap/bridge 网络）
#
# 复刻生产网络拓扑：br-wan（上游网卡）+ br-lan（内网）+ tap 挂桥，
# 用 cloud-hypervisor 启动路由 VM，验证 WAN DHCP / LAN 静态 / NAT / VRRP。
# 与 smoke-test.sh 的「纯 boot 冒烟」互补——那个不接网，这个接真网。
#
# ⚠️ 需要 root，且会把 --uplink 指定的物理网卡临时并入 br-wan。
#   若你的 SSH / 上网流量走这块网卡，测试期间会断，退出后自动恢复。
#
# 用法:
#   sudo test/cloud-hypervisor-env.sh --uplink <网卡> [--distro alpine|gentoo]
#
# 选项:
#   --uplink IFACE    上游网卡（必填；并入 br-wan，VM 的 WAN 从此拿 DHCP）
#   --distro NAME     alpine | gentoo（默认 alpine）
#   --assets-dir DIR  镜像资产目录（默认 <仓库>/build/smoke-assets）
#   --wan-bridge NAME WAN 桥名（默认 br-wan）
#   --lan-bridge NAME LAN 桥名（默认 br-lan）
#   -h|--help         本帮助
#
# 前置: 先下载并校验镜像资产（cloud-hypervisor 装好即可，不需要 qemu）
#   test/smoke-test.sh alpine --verify-only
#
# 验证点（启动后）:
#   串口登录 root/root → ip a：eth0 拿到上游 DHCP 地址、eth1=192.168.10.1
#   → nft list ruleset、rc-status、以及 LAN 侧挂一台设备看能否拿到 DHCP
# ============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DISTRO="alpine"
ASSETS_DIR="${REPO_ROOT}/build/smoke-assets"
UPLINK=""
WAN_BRIDGE="br-wan"
LAN_BRIDGE="br-lan"
TAP_WAN="router-wan"
TAP_LAN="router-lan"
MAC_WAN="02:00:00:01:00:01"
MAC_LAN="02:00:00:01:00:02"

usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
log() { printf '[ch-env] %s\n' "$*" >&2; }
die() { printf '[ch-env] 错误: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        --uplink)       UPLINK="${2:?--uplink 需要值}"; shift 2 ;;
        --distro)       DISTRO="${2:?--distro 需要值}"; shift 2 ;;
        --assets-dir)   ASSETS_DIR="${2:?--assets-dir 需要值}"; shift 2 ;;
        --wan-bridge)   WAN_BRIDGE="${2:?--wan-bridge 需要值}"; shift 2 ;;
        --lan-bridge)   LAN_BRIDGE="${2:?--lan-bridge 需要值}"; shift 2 ;;
        *) die "未知参数: $1（见 --help）" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "需要 root（要操作网卡/桥/tap，用 sudo 跑）"
command -v cloud-hypervisor >/dev/null 2>&1 || die "未找到 cloud-hypervisor（Arch: sudo pacman -S cloud-hypervisor）"
[ -n "$UPLINK" ] || die "必须用 --uplink 指定上游网卡（例如 eth0 / enp3s0）"
ip link show "$UPLINK" >/dev/null 2>&1 || die "网卡不存在: $UPLINK"
case "$DISTRO" in alpine|gentoo) ;; *) die "distro 只支持 alpine|gentoo" ;; esac
for f in vmlinuz-virt initrd "${DISTRO}-rootfs.qcow2"; do
    [ -f "$ASSETS_DIR/$f" ] || die "缺少 $ASSETS_DIR/$f（先跑: test/smoke-test.sh $DISTRO --verify-only）"
done

# 只清理本次新建的桥；tap 和 uplink 的归属始终还原
CREATED_BRIDGES=()

setup_net() {
    local b
    for b in "$WAN_BRIDGE" "$LAN_BRIDGE"; do
        if ! ip link show "$b" >/dev/null 2>&1; then
            ip link add "$b" type bridge
            CREATED_BRIDGES+=("$b")
            log "创建桥 $b"
        else
            log "复用已有桥 $b"
        fi
    done

    # 上游网卡并入 br-wan（L2：VM 的 DHCP 广播经此出网，宿主自身 IP 不动）
    ip link set "$UPLINK" master "$WAN_BRIDGE"
    log "网卡 $UPLINK → $WAN_BRIDGE"

    # 创建 tap 并挂桥（与生产 microvm 一致：tap 先建、再挂桥）
    ip tuntap add dev "$TAP_WAN" mode tap
    ip tuntap add dev "$TAP_LAN" mode tap
    ip link set "$TAP_WAN" master "$WAN_BRIDGE"
    ip link set "$TAP_LAN" master "$LAN_BRIDGE"

    ip link set "$WAN_BRIDGE" up
    ip link set "$LAN_BRIDGE" up
    ip link set "$UPLINK" up
    ip link set "$TAP_WAN" up
    ip link set "$TAP_LAN" up
    log "tap $TAP_WAN → $WAN_BRIDGE, $TAP_LAN → $LAN_BRIDGE 已就绪"
}

cleanup_net() {
    log "清理网络 ..."
    ip link del "$TAP_WAN" 2>/dev/null || true
    ip link del "$TAP_LAN" 2>/dev/null || true
    ip link set "$UPLINK" nomaster 2>/dev/null || true
    ip link set "$UPLINK" up 2>/dev/null || true
    for b in "${CREATED_BRIDGES[@]}"; do
        ip link del "$b" 2>/dev/null || true
    done
    log "清理完成"
}

boot_ch() {
    log "cloud-hypervisor 启动 $DISTRO（Ctrl+C 退出并自动清理网络）"
    cloud-hypervisor \
        --kernel "$ASSETS_DIR/vmlinuz-virt" \
        --initramfs "$ASSETS_DIR/initrd" \
        --cmdline "console=ttyS0 root=/dev/vda rootfstype=ext4 rw" \
        --disk "path=$ASSETS_DIR/${DISTRO}-rootfs.qcow2" \
        --cpus boot=2 \
        --memory size=512M \
        --serial tty --console off \
        --net "tap=$TAP_WAN,mac=$MAC_WAN" \
        --net "tap=$TAP_LAN,mac=$MAC_LAN"
}

trap cleanup_net EXIT INT TERM
setup_net
boot_ch
