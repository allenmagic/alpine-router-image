#
# distros/gentoo/check.sh —— Gentoo (openrc) 构建完整性检查
#   被 setup.sh source 调用，运行在 stage3 环境内
#   检查目标为 TARGET_ROOTFS（/gentoo-rootfs），不是当前根文件系统
#

check_rootfs() {
    echo "[check] === 构建完整性检查 ==="
    _OK=0; _FAIL=0

    # ---------- 1. 关键二进制（在 TARGET_ROOTFS 内查找）----------
    _check_bin() { _b_="$1"; shift
        for _p_ in "$@"; do
            if [ -x "${TARGET_ROOTFS}${_p_}" ]; then
                echo "  ✓ $_b_"; _OK=$((_OK + 1)); return 0
            fi
        done
        echo "  ✗ $_b_ 缺失!"; _FAIL=$((_FAIL + 1))
    }
    echo "[check] 二进制:"
    _check_bin bash     /bin/bash
    _check_bin busybox  /bin/busybox
    _check_bin sshd     /usr/sbin/sshd
    _check_bin dnsmasq  /usr/sbin/dnsmasq /usr/bin/dnsmasq
    _check_bin nft      /usr/sbin/nft /sbin/nft
    _check_bin tailscaled /usr/local/bin/tailscaled
    _check_bin cloudflared /usr/local/bin/cloudflared
    _check_bin network-watchdog /usr/local/bin/network-watchdog

    # ---------- 2. 配置文件占位符残留 ----------
    _check_no_placeholder() { _f_="$1"
        [ -f "$_f_" ] || { echo "  ✗ $_f_ 不存在!"; _FAIL=$((_FAIL + 1)); return; }
        if grep -q '__[A-Z_]\+__' "$_f_" 2>/dev/null; then
            echo "  ✗ $_f_ 有未替换占位符!"; _FAIL=$((_FAIL + 1))
            grep -n '__[A-Z_]\+__' "$_f_"
        else
            echo "  ✓ $_f_"; _OK=$((_OK + 1))
        fi
    }
    echo "[check] 配置占位符:"
    for _f_ in "${TARGET_ROOTFS}"/etc/dnsmasq.d/*.conf "${TARGET_ROOTFS}"/etc/nftables.d/*.nft; do
        [ -f "$_f_" ] && _check_no_placeholder "$_f_"
    done

    # ---------- 3. openrc 服务启用 ----------
    _check_openrc() { _s_="$1" _rl_="${2:-default}"
        if [ -x "${TARGET_ROOTFS}/etc/init.d/$_s_" ]; then
            if [ -L "${TARGET_ROOTFS}/etc/runlevels/$_rl_/$_s_" ]; then
                echo "  ✓ $_s_ ($_rl_)"; _OK=$((_OK + 1))
            else
                echo "  ✗ $_s_ init 脚本存在但未在 $_rl_ runlevel 注册"; _FAIL=$((_FAIL + 1))
            fi
        else
            echo "  ✗ $_s_ init 脚本缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }
    echo "[check] openrc 系统服务:"
    _check_openrc bootmisc boot
    _check_openrc syslog default
    _check_openrc crond default

    echo "[check] openrc 应用服务:"
    _check_openrc sshd default
    _check_openrc busybox-ntpd default
    _check_openrc nftables default
    _check_openrc dnsmasq default
    _check_openrc tailscale default
    _check_openrc cloudflared default
    _check_openrc network-watchdog
    _check_openrc network
    _check_openrc keepalived

    # ---------- 4. 额外检查：自定义 init 脚本完整性 ----------
    echo "[check] Gentoo 自定义 init 脚本:"
    for _s_ in busybox-ntpd syslog crond; do
        if [ -x "${TARGET_ROOTFS}/etc/init.d/$_s_" ]; then
            echo "  ✓ $_s_"; _OK=$((_OK + 1))
        else
            echo "  ✗ $_s_ init 脚本缺失!"; _FAIL=$((_FAIL + 1))
        fi
    done

    # ---------- 结果 ----------
    _TOTAL=$((_OK + _FAIL))
    echo "[check] === $_OK/$_TOTAL 通过 ==="
    [ "$_FAIL" -eq 0 ] || echo "[check] 警告: $_FAIL 项检查未通过"
}
