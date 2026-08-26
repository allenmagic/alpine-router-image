#
# distros/alpine/check.sh —— Alpine (openrc) 构建完整性检查
#   被 setup.sh source 调用，在清理步骤之前执行
#

check_rootfs() {
    echo "[check] === 构建完整性检查 ==="
    _OK=0; _FAIL=0

    # ---------- 1. 关键二进制 ----------
    _check_bin() { _b_="$1"
        if command -v "$_b_" >/dev/null 2>&1; then
            echo "  ✓ $_b_"; _OK=$((_OK + 1))
        else
            echo "  ✗ $_b_ 缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }
    echo "[check] 二进制:"
    _check_bin bash
    _check_bin sshd
    _check_bin chronyd
    _check_bin dnsmasq
    _check_bin nft
    _check_bin tailscaled
    _check_bin cloudflared
    _check_bin network-watchdog

    # sing-box 仅在 INFRA=sing-box 时检查
    case ",${INFRA:-base}," in *",sing-box,"*)
        _check_bin sing-box
    ;; esac

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
    for _f_ in /etc/dnsmasq.d/*.conf /etc/nftables.d/*.nft; do
        [ -f "$_f_" ] && _check_no_placeholder "$_f_"
    done

    # ---------- 3. openrc 服务启用 ----------
    _check_openrc() { _s_="$1" _rl_="${2:-default}"
        if [ -x "/etc/init.d/$_s_" ]; then
            if rc-update show 2>/dev/null | grep -q "$_s_"; then
                echo "  ✓ $_s_"; _OK=$((_OK + 1))
            else
                echo "  ✗ $_s_ init 脚本存在但未在 $_rl_ runlevel 注册"; _FAIL=$((_FAIL + 1))
            fi
        else
            echo "  ✗ $_s_ init 脚本缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }
    echo "[check] openrc 服务:"
    _check_openrc sshd
    _check_openrc chronyd
    _check_openrc nftables
    _check_openrc dnsmasq
    _check_openrc tailscale
    _check_openrc cloudflared
    _check_openrc network-watchdog

    # sing-box 仅在 INFRA=sing-box 时检查
    case ",${INFRA:-base}," in *",sing-box,"*)
        _check_openrc sing-box
    ;; esac

    # ---------- 结果 ----------
    _TOTAL=$((_OK + _FAIL))
    echo "[check] === $_OK/$_TOTAL 通过 ==="
    [ "$_FAIL" -eq 0 ] || { echo "[check] 构建不完整，中止"; exit 1; }
}
