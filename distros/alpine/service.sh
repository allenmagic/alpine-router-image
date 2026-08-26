#
# distros/alpine/service.sh —— Alpine (OpenRC) 服务启用
#   被 setup.sh source 调用
#   定义 enable_router_services() 函数
#

enable_router_services() {
    echo "[service] === 启用路由器服务 (INFRA=${INFRA:-base}) ==="

    # --- 系统基础服务 ---
    _enable_service bootmisc boot
    _enable_service syslog
    _enable_service crond

    # --- base 应用服务（按依赖顺序）---
    # 1. 防火墙（最先加载）
    _enable_nftables

    # 2. 核心网络服务
    _enable_service dnsmasq

    # 3. 基础应用服务
    _enable_service sshd
    _enable_service chronyd

    # 4. VPN 和隧道服务
    _enable_service tailscale
    _enable_cloudflared

    # 5. 监控服务
    _enable_service network-watchdog

    # --- 根据 INFRA 启用组件服务 ---
    case ",${INFRA:-base}," in
        *",sing-box,"*)
            echo "[service] --- sing-box 服务 ---"
            _enable_singbox
            ;;
    esac

    echo "[service] === 服务启用完成 ==="
}

# 通用服务启用
# _enable_service <name> [runlevel]
#   runlevel 可选，默认 default
_enable_service() {
    _svc_="$1"
    _rl_="${2:-default}"
    if [ -f "/etc/init.d/${_svc_}" ]; then
        rc-update add "${_svc_}" "${_rl_}" 2>/dev/null || true
        echo "[service]   启用: ${_svc_} (${_rl_})"
    fi
}

# nftables 开机加载
_enable_nftables() {
    echo "[service] 启用 nftables 开机加载 ..."
    rc-update add nftables default 2>/dev/null || true
}

# sing-box 服务启用
_enable_singbox() {
    echo "[service] 启用 sing-box ..."
    rc-update add sing-box default 2>/dev/null || true
}

# cloudflared 服务启用
_enable_cloudflared() {
    echo "[service] 启用 cloudflared ..."
    rc-update add cloudflared default 2>/dev/null || true
}
