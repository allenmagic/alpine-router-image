#!/bin/sh
# /usr/local/bin/network-watchdog.sh
# 网络看门狗 —— 监测 WAN/LAN 连通性，断线时自动恢复
#
# 检测逻辑：
#   1. WAN: ping 公网（223.5.5.5）
#   2. LAN: 检查接口 IP 配置
#   3. 任一异常 → 重启对应接口 + 重启路由服务
#
# 用法:
#   network-watchdog.sh check           # 单次检查
#   network-watchdog.sh daemon-start    # 启动后台守护进程
#   network-watchdog.sh daemon-stop     # 停止守护进程

set -e

# ==================== 配置 ====================
WAN_IF="${WAN_IF:-eth0}"
LAN_IF="${LAN_IF:-eth1}"
LAN_IP="${LAN_IP:-192.168.8.1}"

PING_TARGET="223.5.5.5"
PING_COUNT=3
PING_TIMEOUT=5
CHECK_INTERVAL=300

LOG_FILE="/var/log/network-watchdog.log"
PID_FILE="/var/run/network-watchdog.pid"

# ==================== 日志 ====================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
    logger -t network-watchdog "$1" 2>/dev/null || true
}

# ==================== 检测 + 重启 ====================
check_and_restart() {
    local wan_ok=0
    local lan_ok=0

    # 检测 WAN（ping 公网）
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" >/dev/null 2>&1; then
        wan_ok=1
    fi

    # 检测 LAN（检查接口是否有配置的 IP）
    if ip addr show "$LAN_IF" 2>/dev/null | grep -q "inet $LAN_IP"; then
        lan_ok=1
    fi

    # 都正常，直接返回
    if [ "$wan_ok" -eq 1 ] && [ "$lan_ok" -eq 1 ]; then
        return 0
    fi

    # 记录问题
    if [ "$wan_ok" -eq 0 ]; then
        log "[WARN] WAN 断网"
    fi
    if [ "$lan_ok" -eq 0 ]; then
        log "[WARN] LAN 接口异常（IP 不匹配）"
    fi

    log "[INFO] 开始重启网络服务..."

    # 重启 LAN 接口
    if [ "$lan_ok" -eq 0 ]; then
        log "[INFO] 重启 LAN 接口 ${LAN_IF}..."
        # Alpine/Debian: ifupdown
        if command -v ifdown >/dev/null 2>&1; then
            ifdown "$LAN_IF" 2>/dev/null || true
            sleep 1
            ifup "$LAN_IF" 2>/dev/null || true
        # Gentoo: netifrc
        elif rc-service --exists "net.${LAN_IF}" 2>/dev/null; then
            rc-service "net.${LAN_IF}" restart 2>/dev/null || true
        # Void/通用: 手动 ip 命令
        else
            ip link set "$LAN_IF" down 2>/dev/null || true
            sleep 1
            ip link set "$LAN_IF" up 2>/dev/null || true
        fi
    fi

    # 重启 WAN 接口
    if [ "$wan_ok" -eq 0 ]; then
        log "[INFO] 重启 WAN 接口 ${WAN_IF}..."
        # Alpine/Debian: ifupdown
        if command -v ifdown >/dev/null 2>&1; then
            ifdown "$WAN_IF" 2>/dev/null || true
            sleep 2
            ifup "$WAN_IF" 2>/dev/null || true
        # Gentoo: netifrc
        elif rc-service --exists "net.${WAN_IF}" 2>/dev/null; then
            rc-service "net.${WAN_IF}" restart 2>/dev/null || true
        # Void: dhcpcd
        elif command -v dhcpcd >/dev/null 2>&1; then
            ip link set "$WAN_IF" down 2>/dev/null || true
            sleep 2
            ip link set "$WAN_IF" up 2>/dev/null || true
            dhcpcd "$WAN_IF" 2>/dev/null || true
        # 通用: 手动 ip 命令
        else
            ip link set "$WAN_IF" down 2>/dev/null || true
            sleep 2
            ip link set "$WAN_IF" up 2>/dev/null || true
        fi

        # PPPoE: 重启拨号
        if ip link show ppp0 >/dev/null 2>&1; then
            log "[INFO] 重启 PPPoE 拨号..."
            killall pppd 2>/dev/null || true
            rc-service ppp.wan restart 2>/dev/null || \
            service ppp restart 2>/dev/null || \
            systemctl restart ppp@wan 2>/dev/null || true
        fi
    fi

    # 重启路由服务
    for svc in nftables dnsmasq sing-box tailscale tailscaled cloudflared; do
        if rc-service --exists "$svc" 2>/dev/null || \
           [ -f "/etc/init.d/$svc" ] || \
           systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
            log "[INFO] 重启 $svc..."
            rc-service "$svc" restart 2>/dev/null || \
            service "$svc" restart 2>/dev/null || \
            systemctl restart "$svc" 2>/dev/null || \
            sv restart "$svc" 2>/dev/null || true
        fi
    done

    sleep 10

    # 验证恢复
    local recovered=0
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" >/dev/null 2>&1 && \
       ip addr show "$LAN_IF" 2>/dev/null | grep -q "inet $LAN_IP"; then
        log "[INFO] WAN + LAN 已恢复"
        recovered=1
    else
        if ! ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" >/dev/null 2>&1; then
            log "[ERROR] WAN 重启后仍断网"
        fi
        if ! ip addr show "$LAN_IF" 2>/dev/null | grep -q "inet $LAN_IP"; then
            log "[ERROR] LAN 重启后仍异常"
        fi
    fi
}

# ==================== 守护进程 ====================
daemon_start() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "守护进程已在运行"
        return
    fi

    log "[INFO] 启动网络看门狗守护进程（间隔 ${CHECK_INTERVAL}s / 5分钟）"
    (
        while true; do
            check_and_restart
            sleep "$CHECK_INTERVAL"
        done
    ) &
    echo $! > "$PID_FILE"
    echo "守护进程已启动 (PID: $(cat "$PID_FILE"))"
}

daemon_stop() {
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null && echo "守护进程已停止"
        rm -f "$PID_FILE"
    else
        echo "守护进程未运行"
    fi
}

# ==================== 入口 ====================
case "${1:-check}" in
    daemon-start) daemon_start ;;
    daemon-stop)  daemon_stop ;;
    check)        check_and_restart ;;
    *)
        echo "用法: $0 {check|daemon-start|daemon-stop}"
        exit 1
        ;;
esac
