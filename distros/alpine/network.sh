#
# distros/alpine/network.sh —— Alpine (OpenRC/ifupdown) 网络配置
#   被 setup.sh source 调用
#   定义 configure_network() 函数
#

configure_network() {
    echo "[network] === 配置网络 (Alpine/ifupdown) ==="
    . /network.env

    _replace_placeholders

    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto ${WAN_IFACE}
iface ${WAN_IFACE} inet dhcp

auto ${LAN_IFACE}
iface ${LAN_IFACE} inet static
    address ${LAN_IP}
    netmask ${LAN_NETMASK}
EOF

    echo "[network] === 网络配置完成 ==="
}

# 通用占位符替换（所有 distro 共用逻辑）
_replace_placeholders() {
    # dnsmasq 配置（主配置的 interface=__LAN_IFACE__ + 模块化 DHCP 配置）
    for _f_ in /etc/dnsmasq.conf /etc/dnsmasq.d/*.conf; do
        [ -f "${_f_}" ] || continue
        sed -i \
            -e "s|__LAN_IFACE__|${LAN_IFACE}|g" \
            -e "s|__LAN_IP__|${LAN_IP}|g" \
            -e "s|__DHCP_RANGE_START__|${DHCP_RANGE_START}|g" \
            -e "s|__DHCP_RANGE_END__|${DHCP_RANGE_END}|g" \
            -e "s|__DHCP_LEASE_TIME__|${DHCP_LEASE_TIME}|g" \
            -e "s|__LAN_NETMASK__|${LAN_NETMASK}|g" \
            -e "s|__LAN_NETWORK__|${LAN_NETWORK}|g" \
            "${_f_}"
    done
    # nftables vars
    _NFT="/etc/nftables.d/00-inet-vars.nft"
    if [ -f "${_NFT}" ]; then
        sed -i \
            -e "s|__WAN_IFACE__|${WAN_IFACE}|g" \
            -e "s|__LAN_IFACE__|${LAN_IFACE}|g" \
            -e "s|__ROUTER_LAN_IP__|${LAN_IP}|g" \
            -e "s|__LAN_NET__|${LAN_NETWORK}|g" \
            "${_NFT}"
    fi
    # tailscale（hostname 与通告路由）
    _TS="/etc/tailscale/config.json"
    if [ -f "${_TS}" ]; then
        sed -i \
            -e "s|__TS_HOSTNAME__|${TS_HOSTNAME}|g" \
            -e "s|__TS_ADVERTISE_ROUTES__|\"${TS_ADVERTISE_ROUTES}\"|g" \
            "${_TS}"
    fi
}
