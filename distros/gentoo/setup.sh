#!/bin/sh
#
# distros/gentoo/setup.sh —— Gentoo chroot 内设置（在 stage3 环境中运行）
#   用 ROOT= emerge 安装包到目标 rootfs + 部署配置 + 系统设置 + 启用服务
#
set -eu

ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-gentoo}"
TARGET_ROOTFS="${TARGET_ROOTFS:-/gentoo-rootfs}"
SERIAL_DEV="${SERIAL_DEV:-ttyS0}"   # VM 串口（R3S 是 ttyS2）
SERIAL_BAUD="${SERIAL_BAUD:-115200}"
GENTOO_MIRROR_BASE="${GENTOO_MIRROR_BASE:-https://distfiles.gentoo.org}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /download-helpers.sh

# ============================================================
#  0. 初始化目标 rootfs 基础目录结构
# ============================================================
echo "[setup] === 初始化目标 rootfs: ${TARGET_ROOTFS} ==="
mkdir -p "${TARGET_ROOTFS}"/{dev,proc,sys,run,tmp,var,etc,usr,root,home}
mkdir -p "${TARGET_ROOTFS}"/var/{cache,lib,log,run,empty,tmp/portage}
mkdir -p "${TARGET_ROOTFS}"/usr/{bin,sbin,lib,local}
mkdir -p "${TARGET_ROOTFS}"/usr/local/{bin,sbin}
mkdir -p "${TARGET_ROOTFS}"/etc/{init.d,conf.d,portage,env.d}

# 创建基础系统文件（emerge acct-group/* 需要这些文件存在）
echo "[setup] 创建基础系统文件 ..."
cat > "${TARGET_ROOTFS}/etc/group" <<'EOF'
root:x:0:
bin:x:1:
daemon:x:2:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:6:
lp:x:7:
mem:x:8:
kmem:x:9:
wheel:x:10:
cdrom:x:11:
dialout:x:18:
floppy:x:19:
audio:x:29:
video:x:27:
input:x:24:
kvm:x:78:
render:x:999:
sgx:x:998:
shadow:x:997:
EOF

cat > "${TARGET_ROOTFS}/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
EOF

cat > "${TARGET_ROOTFS}/etc/shadow" <<'EOF'
root:!:19000:0:99999:7:::
EOF
chmod 640 "${TARGET_ROOTFS}/etc/shadow"

cat > "${TARGET_ROOTFS}/etc/gshadow" <<'EOF'
root:::
EOF
chmod 640 "${TARGET_ROOTFS}/etc/gshadow"

# ============================================================
#  1. 配置 Portage（在 stage3 环境内）
# ============================================================
echo "[setup] === 配置 Portage ==="

# 计算 CPU 核心数
_NPROC_="$(nproc 2>/dev/null || echo 4)"

# Portage 配置（动态适配：原生 ARM64 多核编译，QEMU 保守单核）
mkdir -p /etc/portage

# 禁用 stage3 自带的官方 binhost：源码编译 20 个用户态包在 4 核 runner 上
# 足够快，而 binpkg 的 GPG 信任链在构建环境里初始化失败（TRUST_UNDEFINED +
# /etc/portage/gnupg 权限混乱）会导致 acct-* 二进制包安装失败
rm -rf /etc/portage/binrepos.conf /etc/portage/binrepos.conf.old 2>/dev/null || true

# 检测是否在 QEMU 用户态模拟下运行
# HOST_ARCH 由 build.sh 传入（宿主的架构），ARCH 为目标架构。
# 原生构建（宿主架构 == 目标架构）：充分利用全部 CPU 核心（CI runner 亦然）；
# 跨架构（QEMU）：单核保守（避免 PTY 耗尽/CLONE_THREAD 问题）。
# 注意：r3s 原版以"宿主 aarch64"判断原生——移植后改为架构相等判断，
# 否则 x86_64 runner 原生构建 x86_64 会被误判为 QEMU 场景而单核。
_native() {
    case "${HOST_ARCH:-$(uname -m)}:${ARCH:-x86_64}" in
        x86_64:x86_64|amd64:amd64|amd64:x86_64|x86_64:amd64) return 0 ;;
        aarch64:aarch64|arm64:arm64|aarch64:arm64|arm64:aarch64) return 0 ;;
    esac
    return 1
}
if _native; then
    _MAKEOPTS_="-j${_NPROC_}"
    _EMERGE_JOBS_="${_NPROC_}"
    # 原生构建：启用 sandbox 保证构建正确性
    _FEATURES_="-getbinpkg"
else
    _MAKEOPTS_="-j1"
    _EMERGE_JOBS_="1"
    # QEMU/WSL2：禁用 sandbox（/dev/pts 无法正常挂载，PTY 会耗尽）
    _FEATURES_="-getbinpkg -sandbox -usersandbox -ipc-sandbox -network-sandbox -pid-sandbox"
fi

cat > /etc/portage/make.conf <<EOF
# Gentoo 镜像源（distfiles 下载）
# 注意：不要追加 /distfiles，ebuild SRC_URI 中 mirror://gentoo/ 已自动拼接该路径
# 加上会导致 distfiles/distfiles 重复路径，部分包（如 netifrc）下载失败
GENTOO_MIRRORS="${GENTOO_MIRROR_BASE}"

# 编译选项（原生: 多核 / QEMU: 单核避免 PTY/CLONE_THREAD 问题）
MAKEOPTS="${_MAKEOPTS_}"
EMERGE_DEFAULT_OPTS="--jobs=${_EMERGE_JOBS_} --quiet-build"

# FEATURES（原生 ARM64 启用 sandbox，QEMU 下禁用）
FEATURES="\${FEATURES} ${_FEATURES_}"
BINPKG_VERIFY_SIGNATURE="no"

# 禁用 binpkg GPG 签名校验（构建环境，非生产系统）
# 防止 portage 调用 getuto 时因缺少 sec-keys/openpgp-keys-gentoo-release 而报错
USE="\${USE} -systemd -gnome -gnome-keyring -binpkg-request-signature"

# 固定 Python 单一目标版本（避免 REQUIRED_USE 冲突）
PYTHON_SINGLE_TARGET="python3_13"
EOF

# package.mask：阻止不必要的包被二进制包反拉
mkdir -p /etc/portage/package.mask
cat > /etc/portage/package.mask/router <<'EOF'
sys-apps/systemd
sys-apps/gentoo-systemd-integration
# udev-init-scripts（源码 404，且路由器用 busybox mdev 无需 udev init）
sys-fs/udev-init-scripts
# shared-mime-info（桌面 MIME 数据库，路由器无用）
x11-misc/shared-mime-info
EOF
# package.use 配置（处理目录情况）
if [ -d "/etc/portage/package.use" ]; then
    # 如果是目录，写入子文件
    cat > /etc/portage/package.use/router <<'EOF'
sys-apps/busybox syslog mdev make-symlinks
app-misc/fastfetch -chafa -ddcutil -drm -efl -elf -vulkan -xrandr -dbus -gnome -imagemagick -lua -opencl -opengl -pulseaudio -sqlite -test -vaapi -vdpau -wayland -X -xcb
sys-apps/systemd-utils -udev
EOF
else
    # 如果是文件或不存在，直接写入
    cat > /etc/portage/package.use <<'EOF'
sys-apps/busybox syslog mdev make-symlinks
app-misc/fastfetch -chafa -ddcutil -drm -efl -elf -vulkan -xrandr -dbus -gnome -imagemagick -lua -opencl -opengl -pulseaudio -sqlite -test -vaapi -vdpau -wayland -X -xcb
sys-apps/systemd-utils -udev
EOF
fi

# 同步 Portage tree（如果还没有）
# 注意：emerge-webrsync 下载 snapshot 时临时用官方源，避免镜像 snapshots 不完整
if [ ! -d "/var/db/repos/gentoo" ] || [ -z "$(ls -A /var/db/repos/gentoo 2>/dev/null)" ]; then
    echo "[setup] 同步 Portage tree（使用官方源）..."
    GENTOO_MIRRORS="https://distfiles.gentoo.org" emerge-webrsync || \
        GENTOO_MIRRORS="https://distfiles.gentoo.org" emerge --sync
fi

# ---------- 初始化 Portage GPG 环境（stage3 内）----------
# stage3 默认不含 /etc/portage/gnupg/，导致 binpkg 签名验证失败
# 即使 make.conf 设置了 -binpkg-verify-signature，Portage 仍可能尝试验证
# 这会导致所有二进制包被拒绝，94 个包全部从源码编译，CI 超时
echo "[setup] 初始化 Portage GPG 环境（stage3 内）..."
mkdir -p /etc/portage/gnupg

# Portage 默认启用 FEATURES=userpriv，binpkg 验证时 GPG 以 portage 用户身份运行
# 如果 keyring 属于 root，会导致 "unsafe ownership" 和 "Permission denied"
if id portage >/dev/null 2>&1; then
    chown -R portage:portage /etc/portage/gnupg
fi

# 尝试运行 getuto 初始化信任链（需要 sec-keys/openpgp-keys-gentoo-release）
# getuto 以 root 运行，完成后需再次确保 portage 用户可读写
if [ -x /usr/bin/getuto ]; then
    echo "[setup]   运行 getuto 初始化 GPG 信任链..."
    getuto 2>/dev/null || echo "[setup]   提示: getuto 失败，继续（已设置 -binpkg-verify-signature）" >&2
    if id portage >/dev/null 2>&1; then
        chown -R portage:portage /etc/portage/gnupg
    fi
else
    echo "[setup]   提示: getuto 不可用，已创建 /etc/portage/gnupg/ 目录" >&2
fi

# 手动部署 Gentoo release GPG 密钥到 TARGET_ROOTFS
# 优先从 stage3 复制，避免硬编码日期 URL 过期
echo "[setup] 手动部署 Gentoo release GPG 密钥到目标 rootfs ..."
mkdir -p "${TARGET_ROOTFS}/usr/share/openpgp-keys"
if [ -f /usr/share/openpgp-keys/gentoo-release.asc ]; then
    cp /usr/share/openpgp-keys/gentoo-release.asc "${TARGET_ROOTFS}/usr/share/openpgp-keys/"
    echo "[setup]   从 stage3 复制 GPG 密钥成功"
else
    echo "[setup]   提示: stage3 无 GPG 密钥（当前已禁用 binpkg 签名校验，不影响安装）" >&2
fi

# ============================================================
#  2. 安装包到目标 rootfs —— 按 package.list 三段安装
# ============================================================
echo "[setup] === 安装系统包到 ${TARGET_ROOTFS} ==="

_PKG_LIST_="/package.list"
_PM_PKGS_=""

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
                _PM_PKGS_="${_PM_PKGS_} ${_pkg_}"
                ;;
            '[dl@'*)
                # dl 包稍后处理（先装完 pm 包）
                ;;
        esac
    done < "${_PKG_LIST_}"
else
    echo "[setup] 警告: ${_PKG_LIST_} 不存在" >&2
fi

# 批量 emerge 安装到 ROOT
# 默认 --binpkg-respect-use=y：拒绝 USE 不匹配的 binpkg，避免 systemd/GNOME 依赖链
# 被二进制包带入 OpenRC 目标 rootfs。缺失的包自动回退到源码编译
# --autounmask=y --autounmask-continue=y --autounmask-keep-masks=y：
# 自动处理 USE/keyword 变更并继续，但保留 package.mask/router 中已有的 mask
if [ -n "${_PM_PKGS_}" ]; then
    echo "[setup] 执行: ROOT=${TARGET_ROOTFS} emerge ${_PM_PKGS_}"
    ROOT="${TARGET_ROOTFS}" emerge --buildpkg=n --autounmask=y --autounmask-continue=y --autounmask-keep-masks=y ${_PM_PKGS_}
fi

# Python 清理：systemd-utils 只用了 tmpfiles（纯 C），Python 仅在构建时通过
# REQUIRED_USE 拉入，运行时不需要。从目标 rootfs 中删除以节省 ~30MB
# 注意：仅删除 /usr/lib/python* 下的运行时库文件，保留包头文件以防万一
echo "[setup] 清理目标 rootfs 中的 Python（运行时不需要）..."
rm -rf "${TARGET_ROOTFS}/usr/lib/python"* \
       "${TARGET_ROOTFS}/usr/lib64/python"* \
       "${TARGET_ROOTFS}/usr/bin/python"* \
       "${TARGET_ROOTFS}/usr/share/python"* \
       "${TARGET_ROOTFS}/usr/include/python"* 2>/dev/null || true

# 处理 [dl@] 下载包（直接下载到 TARGET_ROOTFS）
if [ -f "${_PKG_LIST_}" ]; then
    _section_="base"
    while read -r _line_; do
        [ -z "${_line_}" ] && continue

        case "${_line_}" in
            '# ========== base'*) _section_="base"; continue ;;
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
            '[dl@'*)
                _line_="${_line_#\[dl@}"
                _url_="${_line_%%\] *}"
                _bin_="${_line_#*\] }"
                echo "[setup]   [dl@${_bin_}]"
                # 复用共享下载助手，DESTDIR 指向目标 rootfs
                DESTDIR="${TARGET_ROOTFS}/usr/local/bin" _dl_url "${_url_}" "${_bin_}"
                ;;
        esac
    done < "${_PKG_LIST_}"
fi


# ============================================================
#  2.5. busybox ntpd OpenRC 服务
# ============================================================
echo "[setup] === 配置 busybox ntpd ==="

# init 脚本
cat > "${TARGET_ROOTFS}/etc/init.d/busybox-ntpd" <<'INITEOF'
#!/sbin/openrc-run
description="Busybox NTP daemon"

depend() {
    use dns
    after net
}

start_pre() {
    # 从 RTC 恢复时间（即使不准确也给一个起点，后续 NTP 纠正）
    /bin/busybox hwclock --hctosys --utc 2>/dev/null || true
}

start() {
    ebegin "Starting ntpd"
    start-stop-daemon --start --quiet \
        --make-pidfile \
        --pidfile /run/busybox-ntpd.pid \
        --exec /bin/busybox -- ntpd -d -p pool.ntp.org -p ntp.cloudflare.com
    eend $?
}

stop() {
    ebegin "Stopping ntpd"
    start-stop-daemon --stop --quiet --pidfile /run/busybox-ntpd.pid
    # 关机前同步系统时间到 RTC
    /bin/busybox hwclock --systohc --utc 2>/dev/null || true
    eend $?
}
INITEOF
chmod 755 "${TARGET_ROOTFS}/etc/init.d/busybox-ntpd"

# conf.d
cat > "${TARGET_ROOTFS}/etc/conf.d/busybox-ntpd" <<'CONFEOF'
# NTP 服务器列表
NTP_SERVERS="pool.ntp.org ntp.cloudflare.com"
CONFEOF

# ============================================================
#  2.6. busybox syslogd / crond OpenRC 服务
# ============================================================
echo "[setup] === 配置 busybox syslogd / crond ==="

# syslogd init 脚本
cat > "${TARGET_ROOTFS}/etc/init.d/syslog" <<'INITEOF'
#!/sbin/openrc-run
description="Busybox syslog daemon"

start() {
    ebegin "Starting syslogd"
    start-stop-daemon --start --quiet \
        --exec /bin/busybox -- syslogd -L -s 200 -b 2
    eend $?
}

stop() {
    ebegin "Stopping syslogd"
    start-stop-daemon --stop --quiet --exec /bin/busybox -- syslogd
    eend $?
}
INITEOF
chmod 755 "${TARGET_ROOTFS}/etc/init.d/syslog"

# crond init 脚本
cat > "${TARGET_ROOTFS}/etc/init.d/crond" <<'INITEOF'
#!/sbin/openrc-run
description="Busybox cron daemon"

start() {
    ebegin "Starting crond"
    start-stop-daemon --start --quiet \
        --make-pidfile --pidfile /run/crond.pid \
        --exec /bin/busybox -- crond -l 0 -L /var/log/crond.log
    eend $?
}

stop() {
    ebegin "Stopping crond"
    start-stop-daemon --stop --quiet --pidfile /run/crond.pid
    eend $?
}
INITEOF
chmod 755 "${TARGET_ROOTFS}/etc/init.d/crond"

# 配置时区
if [ -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    cp "/usr/share/zoneinfo/${TIMEZONE}" "${TARGET_ROOTFS}/etc/localtime" 2>/dev/null || true
else
    echo "[setup] 警告：时区文件 /usr/share/zoneinfo/${TIMEZONE} 不存在" >&2
fi

# ============================================================
#  3. 部署配置文件到目标 rootfs
# ============================================================
echo "[setup] === 部署出厂配置到 ${TARGET_ROOTFS} ==="

_deploy_cfg_() {
    _CFG_="/$1"
    [ ! -d "${_CFG_}" ] && return
    echo "[setup]   部署 /${1}/ ..."
    for _f_ in "${_CFG_}"/*; do
        [ ! -e "${_f_}" ] && continue
        _base_="$(basename "${_f_}")"
        [ "${_base_}" = "init" ] && continue
        cp -r "${_f_}" "${TARGET_ROOTFS}/etc/"
    done
    if [ -d "${_CFG_}/init/openrc" ]; then
        cp -f "${_CFG_}/init/openrc/"* "${TARGET_ROOTFS}/etc/init.d/" 2>/dev/null || true
        chmod +x "${TARGET_ROOTFS}"/etc/init.d/* 2>/dev/null || true
    fi
}

# 始终部署 base/
_deploy_cfg_ base
# sing-box 模式叠加部署 sing-box/
case "${INFRA:-base}" in sing-box) _deploy_cfg_ sing-box ;; esac

find "${TARGET_ROOTFS}/etc" \( -name '*.md' -o -name '*.example' \) -exec rm -f {} + 2>/dev/null || true

chmod +x "${TARGET_ROOTFS}"/etc/local.d/*.start 2>/dev/null || true

# 安装运行时脚本到 /usr/local/bin/
echo "[setup] === 安装运行时脚本 ==="
if [ -f "${SCRIPT_DIR}/scripts/network-watchdog.sh" ]; then
    install -m 0755 "${SCRIPT_DIR}/scripts/network-watchdog.sh" "${TARGET_ROOTFS}/usr/local/bin/network-watchdog"
    echo "[setup]   已安装: network-watchdog"
fi

# 统一路径
if [ ! -e "${TARGET_ROOTFS}/usr/local/bin/sing-box" ] && [ -x "${TARGET_ROOTFS}/usr/bin/sing-box" ]; then
    ln -s /usr/bin/sing-box "${TARGET_ROOTFS}/usr/local/bin/sing-box"
fi

# ============================================================
#  3.5. 网络配置（config 文件拷贝完成后替换占位符 + 生成接口配置）
# ============================================================
. /network.sh
configure_network

# ============================================================
#  4. 系统设置（在目标 rootfs 内配置）
# ============================================================
echo "[setup] === 系统设置 ==="

echo "[setup] 设置 root 密码 ..."
# 生成密码哈希（在 stage3 环境）并更新目标 shadow
_hash_="$(openssl passwd -6 "${ROOT_PASSWORD}")"
sed -i "s|^root:[^:]*:|root:${_hash_}:|" "${TARGET_ROOTFS}/etc/shadow"

echo "[setup] 确认默认 shell 为 bash ..."
sed -i '/^root:/ s|:[^:]*$|:/bin/bash|' "${TARGET_ROOTFS}/etc/passwd"

if [ ! -f "${TARGET_ROOTFS}/etc/shells" ]; then
    cat > "${TARGET_ROOTFS}/etc/shells" <<EOF
/bin/sh
/bin/bash
EOF
else
    grep -qx '/bin/bash' "${TARGET_ROOTFS}/etc/shells" 2>/dev/null || echo '/bin/bash' >> "${TARGET_ROOTFS}/etc/shells"
fi

echo "[setup] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > "${TARGET_ROOTFS}/etc/hostname"
# Gentoo 的 hostname 服务读 conf.d/hostname（hostname="..." 格式），
# 仅写 /etc/hostname（Alpine 习惯）在 Gentoo 上不生效
echo "hostname=\"${HOSTNAME_VAL}\"" > "${TARGET_ROOTFS}/etc/conf.d/hostname"
if [ ! -f "${TARGET_ROOTFS}/etc/hosts" ]; then
    cat > "${TARGET_ROOTFS}/etc/hosts" <<EOF
127.0.0.1       localhost
127.0.1.1       ${HOSTNAME_VAL}
::1             localhost ip6-localhost ip6-loopback
EOF
else
    if ! grep -q "127.0.1.1[[:space:]]*${HOSTNAME_VAL}" "${TARGET_ROOTFS}/etc/hosts" 2>/dev/null; then
        printf '127.0.1.1\t%s\n' "${HOSTNAME_VAL}" >> "${TARGET_ROOTFS}/etc/hosts"
    fi
fi

# 确保串口控制台 — 直接覆盖（不用 stage3 自带的 inittab）
# id 字段必须 ≤4 字符，sysvinit 限制；S2 = serial-2（ttyS2）
cat > "${TARGET_ROOTFS}/etc/inittab" <<EOF
id:3:initdefault:
si::sysinit:/sbin/openrc sysinit
rc::bootwait:/sbin/openrc boot
d3::wait:/sbin/openrc default
l0:0:wait:/sbin/openrc shutdown
l6:6:wait:/sbin/openrc reboot
S2::respawn:/sbin/agetty ${SERIAL_BAUD} ${SERIAL_DEV} vt100
EOF

echo "[setup] 启用基础服务 ..."
# OpenRC 服务启用需要在目标 rootfs 的 /etc/runlevels/ 下操作
mkdir -p "${TARGET_ROOTFS}/etc/runlevels"/{boot,default,sysinit}

# ============================================================
#  5. 启用路由器服务（通过修改目标 rootfs 的 runlevels）
# ============================================================
echo "[setup] === 启用服务 ==="

. /service.sh
enable_router_services

# 密钥注入（如果需要在目标 rootfs 内注入）
# 注意：inject-secrets.sh 需要知道目标路径
if [ -x /inject-secrets.sh ]; then
    TARGET_ROOT="${TARGET_ROOTFS}" /bin/sh /inject-secrets.sh
fi

# ============================================================
#  5.5. 构建完整性检查
# ============================================================
. /check.sh
check_rootfs

# ============================================================
#  6. 清理
# ============================================================
echo "[setup] 清理缓存 ..."
rm -rf "${TARGET_ROOTFS}/var/cache/edb/"* 2>/dev/null || true
rm -rf "${TARGET_ROOTFS}/var/tmp/"* 2>/dev/null || true

echo "[setup] 完成。目标 rootfs: ${TARGET_ROOTFS}"
