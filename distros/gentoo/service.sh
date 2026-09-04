#
# distros/gentoo/service.sh —— Gentoo (OpenRC) 服务启用
#   被 setup.sh source 调用
#   定义 enable_router_services() 函数
#   注意：Gentoo 构建模式下，setup.sh 在 stage3 内运行，但直接操作 TARGET_ROOTFS
#

enable_router_services() {
    echo "[service] === 启用路由器服务 ==="

    # --- 系统基础服务 ---
    _enable_service bootmisc boot
    # 运行时状态目录（sysinit：/run 下目录准备，先于一切 default 级服务）
    _enable_service run-state sysinit
    # host key 在 /run/ssh 生成（依赖 run-state，先于 sshd）
    _enable_service sshd-keys sysinit
    _enable_service syslog

    # --- 网络服务（base/init/openrc/network：udhcpc + ip 直接配置）---
    _enable_service network

    # --- base 应用服务（按依赖顺序）---
    # 1. 防火墙（最先加载）
    _enable_service nftables

    # 2. 核心网络服务
    _enable_service dnsmasq

    # 3. 基础应用服务
    _enable_service sshd
    _enable_service ntpd

    # 4. VPN 和隧道服务
    _enable_service tailscale
    _enable_service cloudflared

    # 5. 监控服务
    _enable_service network-watchdog

    # 6. 浮动网关（VRRP）
    _enable_service keepalived

    # 移除 headless 路由器不需要的服务：
    # - keymaps/save-keymaps：依赖未安装的 kbd 包
    # - termencoding/save-termencoding：终端编码设置需要 /dev/ttyN（无 VT
    #   内核下报错），无头 VM 无用
    rm -f "${TARGET_ROOTFS}/etc/runlevels/boot/keymaps" \
          "${TARGET_ROOTFS}/etc/runlevels/boot/save-keymaps" \
          "${TARGET_ROOTFS}/etc/runlevels/default/keymaps" \
          "${TARGET_ROOTFS}/etc/runlevels/default/save-keymaps" \
          "${TARGET_ROOTFS}/etc/runlevels/boot/termencoding" \
          "${TARGET_ROOTFS}/etc/runlevels/boot/save-termencoding" 2>/dev/null || true

    # ro 无状态 guest 下禁用（stage3 默认启用）：
    # - systemd-tmpfiles-setup(-dev)：运行期 tmpfiles 与「构建期烙入的
    #   符号链接」ro 架构冲突（L 类型先 unlink 再建，ro 上必然 EROFS 报错）；
    #   镜像已预烤，运行期无需
    # - seedrng：无状态 guest 无持久化熵池可存；熵源靠 RDRAND 直通 +
    #   内核抖动（2026-09 裁剪审计已移除 CONFIG_HW_RANDOM_VIRTIO——
    #   CH 命令行无 --rng 设备，该驱动本就不工作）
    rm -f "${TARGET_ROOTFS}/etc/runlevels/boot/systemd-tmpfiles-setup" \
          "${TARGET_ROOTFS}/etc/runlevels/sysinit/systemd-tmpfiles-setup-dev" \
          "${TARGET_ROOTFS}/etc/runlevels/boot/seedrng" 2>/dev/null || true

    echo "[service] === 服务启用完成 ==="
}

# 通用服务启用（直接操作 TARGET_ROOTFS 符号链接）
# _enable_service <name> [runlevel]
#   runlevel 可选，默认 default
_enable_service() {
    _svc_="$1"
    _rl_="${2:-default}"
    if [ -f "${TARGET_ROOTFS}/etc/init.d/${_svc_}" ]; then
        mkdir -p "${TARGET_ROOTFS}/etc/runlevels/${_rl_}"
        ln -sf "/etc/init.d/${_svc_}" "${TARGET_ROOTFS}/etc/runlevels/${_rl_}/${_svc_}" 2>/dev/null || true
        echo "[service]   启用: ${_svc_} (${_rl_})"
    fi
}
