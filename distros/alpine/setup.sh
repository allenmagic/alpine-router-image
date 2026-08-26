#!/bin/sh
#
# distros/alpine/setup.sh —— Alpine chroot 内设置（OpenRC）
#   安装包 + 部署配置 + 系统设置 + 启用服务
#
set -eu

ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-alpine}"
MIRROR="${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
SERIAL_DEV="${SERIAL_DEV:-ttyS2}"
SERIAL_BAUD="${SERIAL_BAUD:-1500000}"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /download-helpers.sh

# ============================================================
#  1. 安装包 —— 按 package.list 三段安装
# ============================================================
echo "[setup] === 安装系统包 ==="

_PKG_LIST_="/package.list"
if [ -f "${_PKG_LIST_}" ]; then
    while read -r _line_; do
        [ -z "${_line_}" ] && continue

        case "${_line_}" in
            '# ========== base'*)
                _section_="base"
                echo "[setup] --- 段: base ---"
                continue
                ;;
            '# ========== sing-box'*)
                case ",${INFRA:-base}," in *",sing-box,"*) _section_="packages" ;; *) _section_="skip" ;; esac
                continue
                ;;
            '# ========== landscape'*)
                _section_="skip"
                continue
                ;;
            '#'*) continue ;;
        esac

        [ "${_section_}" = "skip" ] && continue

        case "${_line_}" in
            '[pm]'*)
                _pkg_="${_line_#\[pm\] }"
                echo "[setup]   [pm] ${_pkg_}"
                apk add --no-cache "${_pkg_}"
                ;;
            '[dl@'*)
                _line_="${_line_#\[dl@}"
                _url_="${_line_%%\] *}"
                _bin_="${_line_#*\] }"
                echo "[setup]   [dl@${_bin_}]"
                _dl_url "${_url_}" "${_bin_}"
                ;;
        esac
    done < "${_PKG_LIST_}"
else
    echo "[setup] 警告: ${_PKG_LIST_} 不存在" >&2
fi

# 配置时区
cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || true
apk del tzdata 2>/dev/null || true

# ============================================================
#  2. 部署配置文件
# ============================================================
echo "[setup] === 部署出厂配置 ==="

_deploy_cfg_() {
    _CFG_="/$1"
    [ ! -d "${_CFG_}" ] && return
    echo "[setup]   部署 /${1}/ ..."
    for _f_ in "${_CFG_}"/*; do
        [ ! -e "${_f_}" ] && continue
        _base_="$(basename "${_f_}")"
        [ "${_base_}" = "init" ] && continue
        cp -r "${_f_}" /etc/
    done
    if [ -d "${_CFG_}/init/openrc" ]; then
        cp -f "${_CFG_}/init/openrc/"* /etc/init.d/ 2>/dev/null || true
        chmod +x /etc/init.d/* 2>/dev/null || true
    fi
}

# 始终部署 base/
_deploy_cfg_ base
# sing-box 模式叠加部署 sing-box/
case "${INFRA:-base}" in sing-box) _deploy_cfg_ sing-box ;; esac

find /etc \( -name '*.md' -o -name '*.example' \) -exec rm -f {} + 2>/dev/null || true

chmod +x /etc/local.d/*.start 2>/dev/null || true

# 安装运行时脚本到 /usr/local/bin/
echo "[setup] === 安装运行时脚本 ==="
if [ -f /scripts/network-watchdog.sh ]; then
    install -m 0755 /scripts/network-watchdog.sh /usr/local/bin/network-watchdog
    echo "[setup]   已安装: network-watchdog"
fi

# 统一路径
if [ ! -e /usr/local/bin/sing-box ] && [ -x /usr/bin/sing-box ]; then
    ln -s /usr/bin/sing-box /usr/local/bin/sing-box
fi

# ============================================================
#  2.5. 网络配置（config 文件拷贝完成后替换占位符 + 生成接口配置）
# ============================================================
. /network.sh
configure_network

# ============================================================
#  3. 系统设置
# ============================================================
echo "[setup] === 系统设置 ==="

echo "[setup] 设置 root 密码 ..."
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "[setup] 设置默认 shell 为 bash ..."
grep -qx '/bin/bash' /etc/shells 2>/dev/null || echo '/bin/bash' >> /etc/shells
chsh -s /bin/bash root 2>/dev/null || \
    sed -i '/^root:/ s|:[^:]*$|:/bin/bash|' /etc/passwd

echo "[setup] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > /etc/hostname
if ! grep -q "127.0.1.1[[:space:]]*${HOSTNAME_VAL}" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1\t%s\n' "${HOSTNAME_VAL}" >> /etc/hosts
fi

# 确保串口控制台 + 禁用虚拟控制台（无 VT 内核）
if ! grep -q "${SERIAL_DEV}" /etc/inittab 2>/dev/null; then
    echo "${SERIAL_DEV}::respawn:/sbin/agetty -L ${SERIAL_BAUD} ${SERIAL_DEV} vt100" >> /etc/inittab
fi
# 注释掉 tty1-tty6（Alpine busybox init 用设备名作 id）
sed -i 's/^tty[1-6]:/#&/' /etc/inittab 2>/dev/null || true

echo "[setup] 启用基础服务 ..."
rc-update add sysctl boot 2>/dev/null || true
rc-update add local default 2>/dev/null || true
rc-update add networking default 2>/dev/null || true

# ============================================================
#  4. 启用路由器服务
# ============================================================
echo "[setup] === 启用服务 ==="
. /service.sh
enable_router_services

# 密钥注入
[ -x /inject-secrets.sh ] && /bin/sh /inject-secrets.sh

# ============================================================
#  4.5. 构建完整性检查
# ============================================================
. /check.sh
check_rootfs

# ============================================================
#  5. 清理
# ============================================================
rm -rf /var/cache/apk/* 2>/dev/null || true
echo "[setup] 完成。"
