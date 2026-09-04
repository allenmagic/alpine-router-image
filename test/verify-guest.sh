#!/bin/sh
# guest 内自检：验证内核能力与镜像装配的正确性
#
# 为什么需要它而不是只看启动日志：启动日志能证明「没崩」，证明不了「能力完整」。
# 最典型的是 openrc 的 modules 服务——它用 `modprobe -q` 且在 while 管道里丢弃
# 返回码，-q 会完全吞掉 "FATAL: Module not found"。所以九个模块全部加载失败时，
# 日志里只有 "Loading modules [ ok ]"，一个字的错误都没有。这类问题**只能**在
# guest 内查状态才能发现。
#
# 用法（smoke-test 启动后登录 root/root，粘贴到串口）：
#   sh /root/verify-guest.sh
# 或从宿主：
#   test/smoke-test.sh alpine
#   # 登录后手工执行本脚本内容
#
# 退出码 0 = 全通过；非 0 = 失败项数
set -u

FAILS=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

head_ "内核与模块元数据"
KREL="$(uname -r)"
ok "内核版本: $KREL"
if [ -d "/lib/modules/$KREL" ]; then
    ok "/lib/modules/$KREL 存在"
    # modprobe 对 builtin 项返回 0 的前提是 modules.builtin.bin 存在
    if [ -f "/lib/modules/$KREL/modules.builtin.bin" ]; then
        ok "modules.builtin.bin 存在（modprobe 可判定 builtin）"
    else
        bad "缺 modules.builtin.bin —— modprobe 对 builtin 项会报 FATAL"
    fi
else
    bad "缺 /lib/modules/$KREL —— /etc/modules 与 modules-load.d 的项全部会失败"
    echo "      实际存在的模块目录: $(ls -1 /lib/modules/ 2>/dev/null | tr '\n' ' ')"
fi

head_ "入口模块可解析（/etc/modules + modules-load.d 的实际内容）"
# 不硬编码清单：从镜像内配置读取，改配置自动跟随
ENTRIES="$(cat /etc/modules 2>/dev/null; cat /etc/modules-load.d/*.conf 2>/dev/null | grep -v '^#')"
for m in $ENTRIES; do
    if modprobe "$m" 2>/dev/null; then
        ok "modprobe $m"
    else
        bad "modprobe $m 失败（builtin 也应返回 0，缺元数据才会失败）"
    fi
done

head_ "功能判据（比 modprobe 返回码更可信：直接查能力是否真的在）"
nft list tables >/dev/null 2>&1 && ok "nftables 可用" || bad "nftables 不可用"
[ -c /dev/net/tun ] && ok "/dev/net/tun 存在（tailscale 依赖）" || bad "缺 /dev/net/tun"
[ -c /dev/rtc0 ] && ok "/dev/rtc0 存在（缺 RTC_INTF_DEV 会没有）" || bad "缺 /dev/rtc0"
CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
[ "$CC" = bbr ] && ok "拥塞控制 = bbr" || bad "拥塞控制 = ${CC:-未知}（期望 bbr）"
FW="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
[ "$FW" = 1 ] && ok "ip_forward = 1" || bad "ip_forward = ${FW:-未知}（期望 1）"
# flock：CONFIG_FILE_LOCKING 丢失时报 Function not implemented
if flock -n /tmp/.vg.lock true 2>/dev/null; then
    ok "flock 可用（CONFIG_FILE_LOCKING）"
else
    bad "flock 不可用 —— openrc 依赖它缓存服务依赖"
fi
rm -f /tmp/.vg.lock

head_ "回环接口（dnsmasq 本地查询、本地 ssh 等一切连 127.0.0.1 的东西都要它）"
# 注意别把「设备存在」当成「已启用」：lo 这个 netdev 内核无条件创建，ip a 永远
# 列得出来，DOWN 时的样子是 <LOOPBACK> + qdisc noop 且一条地址都没有
if ip link show lo 2>/dev/null | grep -q '[<,]UP[,>]'; then
    ok "lo 已 up"
    ip addr show lo 2>/dev/null | grep -q 'inet 127\.0\.0\.1' \
        && ok "lo 有 127.0.0.1" || bad "lo 已 up 但没有 127.0.0.1"
    ping -c1 -W1 127.0.0.1 >/dev/null 2>&1 \
        && ok "127.0.0.1 可达" || bad "lo 已 up 但 127.0.0.1 不可达"
else
    bad "lo 处于 DOWN —— loopback 服务未注册进 boot runlevel"
fi

head_ "deploy 就绪（密钥注入前置）"
# sshd 是 deploy 的 scp/ssh 通道（root/root 密码 + 注入公钥后的免密登录）；
# 三符号链接把标准路径指向 /run（tmpfs），deploy 写标准路径即落 tmpfs。
if pgrep sshd >/dev/null 2>&1; then
    ok "sshd 进程运行中"
else
    bad "sshd 未运行（deploy 的 scp/ssh 通道会失败）"
fi
if [ -f /run/router-vm/ssh/ssh_host_ed25519_key ]; then
    ok "host key 已生成（/run/router-vm/ssh，sshd-keys 服务）"
else
    bad "缺 /run/router-vm/ssh host key（sshd-keys 未跑，sshd 无法接受连接）"
fi
_symlink_ok() {
    if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then
        ok "$3：$1 -> $2"
    else
        bad "$3：$1 未指向 $2（deploy 写不进 /run）"
    fi
}
_symlink_ok /root/.ssh             /run/router-vm/ssh     "SSH authorized_keys"
_symlink_ok /etc/cloudflared       /run/router-vm/cloudflared "Cloudflared config"
_symlink_ok /etc/tailscale/authkey /run/router-vm/tailscale/authkey "Tailscale authkey"
for _d in ssh tailscale cloudflared; do
    [ -d "/run/router-vm/$_d" ] && ok "/run/router-vm/$_d 目录存在（run-state）" || bad "缺 /run/router-vm/$_d（run-state 未建）"
done

head_ "服务状态"
CRASHED="$(rc-status --crashed 2>/dev/null)"
[ -z "$CRASHED" ] && ok "无崩溃服务" || bad "崩溃服务: $CRASHED"
NLOADED="$(lsmod 2>/dev/null | tail -n +2 | wc -l)"
echo "  已加载模块数: $NLOADED（自建内核全 builtin 时为 0）"

head_ "结果"
if [ "$FAILS" -eq 0 ]; then
    printf '\033[32m全部通过\033[0m\n'
else
    printf '\033[31m%d 项失败\033[0m\n' "$FAILS"
fi
exit "$FAILS"
