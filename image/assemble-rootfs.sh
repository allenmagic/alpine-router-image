#!/usr/bin/env bash
# rootfs 装配（须以 root 或 fakeroot 环境执行——tar 内 uid 0 属主必须保留，
# 否则镜像里 /var/empty 归属错误，sshd 的 chroot 目录校验会拒绝启动）
#
# 移植自 qnap-nixos-nas 的 microvm/rootfs-image.nix
set -euo pipefail

ROOTFS_TARBALL="$1"
MODLOOP="$2"
OUT_EXT4="$3"
NFT_CHECK_DIR="${4:-}"   # 可选：把 nftables 文件复制到此目录供宿主侧语法验证
CUSTOM_MODULES="${5:-}"  # 可选：kernel/out/modules（自建内核的模块元数据树）

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

mkdir -p rootfs
tar xf "$ROOTFS_TARBALL" -C rootfs --numeric-owner

# ============================================================
# 内核模块：按需拷贝（modloop-virt 全量 → 入口清单 + modinfo 递归依赖闭包）
# ============================================================
# modloop-virt 里是 modules/<ver>/（注意非 lib/modules），与 vmlinuz-virt 配套
unsquashfs -d modloop-x "$MODLOOP" >/dev/null
MV="$(ls modloop-x/modules/ | grep -E '^[0-9]')"
MODSRC="modloop-x/modules/$MV"
MODDST="rootfs/lib/modules/$MV"
mkdir -p "$MODDST"

# 入口模块：从镜像内配置读取（改 modules-load 配置自动跟随）
#   /etc/modules          引导期 modules 服务加载（nf_tables/virtio_net/af_packet…）
#   /etc/modules-load.d/*.conf  附加加载（tun/bbr/sch_fq/nf_conntrack…）
# 固定补充入口（配置之外的需求）：
#   virtio_pci/virtio_vsock  CH 设备族（vsock.cid 已配）
#   ext4 链                  运行期挂载/兼容保险（引导期已由 initrd 加载）
ENTRY="$(cat rootfs/etc/modules 2>/dev/null || true)"
ENTRY="$ENTRY $(cat rootfs/etc/modules-load.d/*.conf 2>/dev/null | grep -v '^#' || true)"
ENTRY="$ENTRY virtio_pci virtio_vsock ext4 jbd2 mbcache crc16"

# 模块名 → 路径 索引
IDX="$WORK/modindex"
find "$MODSRC" -name "*.ko*" 2>/dev/null | while read -r ko; do
    base="${ko##*/}"
    printf '%s %s\n' "${base%%.*}" "$ko"
done > "$IDX"

DONE="$WORK/copied"
: > "$DONE"

# modinfo 递归依赖闭包拷贝（保留模块在 modloop 内的相对路径）
_copy_mod() {
    _name="$1"
    [ -n "$_name" ] || return 0
    _path="$(awk -v n="$_name" '$1==n { print $2; exit }' "$IDX")"
    [ -n "$_path" ] || return 0          # 不在 modloop（内核内建）则跳过
    grep -qx "$_name" "$DONE" && return 0
    echo "$_name" >> "$DONE"

    _rel="${_path#"$MODSRC"/}"
    mkdir -p "$MODDST/$(dirname "$_rel")"
    cp "$_path" "$MODDST/$_rel"

    # 递归依赖（modinfo -F depends 输出逗号分隔，无依赖输出空）
    _deps="$(modinfo -F depends "$_path" 2>/dev/null | tr ',' '\n' || true)"
    for _d in $_deps; do
        [ "$_d" != "-" ] && _copy_mod "$_d"
    done
}

for _m in $ENTRY; do
    _copy_mod "$_m"
done

# netfilter 目录整体保留：nft_*（masq/ct/limit/log…）不是 nf_tables 的
# 依赖，而是 nft 应用规则时运行时 modprobe 的独立模块——依赖闭包无法覆盖，
# 作为路由器核心目录粗粒度保留（几十个模块，体积代价小）
cp -r "$MODSRC/kernel/net" "$MODDST/kernel/" 2>/dev/null || true

# firmware 不拷贝：路由器场景（virtio/tun/netfilter）无固件需求
rm -rf rootfs/lib/firmware 2>/dev/null || true

# 重建模块索引（modprobe 读 modules.dep.bin 二进制索引，必须 depmod）
depmod -b rootfs "$MV"

echo "[assemble-rootfs] 模块精简：$(wc -l < "$DONE") 个（含依赖闭包）"

# ============================================================
# 自建内核（router.nix 的 kernel = "custom"）的模块元数据
# ============================================================
# 与上面的 modloop 闭包并存：目录名是内核版本串（modloop 为 6.18.x-0-virt，
# 自建为 6.18.x），彼此不同故互不干扰，由启动内核的 uname -r 决定命中哪份。
# 自建内核 0 个 .ko（引导链全 builtin），这里只有 depmod 元数据 ~108K，其中
# modules.builtin.bin 让 modprobe 对 builtin 项返回成功。
# 缺它的后果实测过：/etc/modules 与 modules-load.d 里那 9 项全部失败
#   modprobe: FATAL: Module nf_tables not found in directory /lib/modules/<ver>
# 而 openrc 的 modules 服务用 `modprobe -q`（-q 完全吞掉这条错误消息）且在
# while 管道里丢弃返回码，于是启动日志里只有 "Loading modules [ ok ]"，
# 一个字的错误都没有——启动日志检不出来，只能靠 test/verify-guest.sh 在
# guest 内查 /lib/modules/$(uname -r) 与逐项 modprobe。
if [ -n "$CUSTOM_MODULES" ] && [ -d "$CUSTOM_MODULES/lib/modules" ]; then
    for _src in "$CUSTOM_MODULES"/lib/modules/*/; do
        [ -d "$_src" ] || continue
        _ver="$(basename "$_src")"
        [ "$_ver" = "$MV" ] && continue      # 与 modloop 同名则跳过（不覆盖）
        mkdir -p "rootfs/lib/modules/$_ver"
        cp -a "$_src." "rootfs/lib/modules/$_ver/"
        echo "[assemble-rootfs] 自建内核元数据: $_ver（$(du -sh "rootfs/lib/modules/$_ver" | cut -f1)，0 个 .ko）"
    done
fi

# ============================================================
# 引导期自动加载：r3s 的 modules 服务注册在 default runlevel，
# 字母序排在 nftables/networking 之后；nf_tables 必须提前就位
# ============================================================
cat >> rootfs/etc/modules <<'MODULES'
nf_tables
virtio_net
MODULES

# 启用 ttyS0 getty：r3s 产物默认注释（Alpine 默认状态）。
# vmlinuz-virt 内建 8250 串口驱动，microvm 控制台/串口访问依赖它
sed -i 's|^#ttyS0:|ttyS0:|' rootfs/etc/inittab

# 复制 nftables 文件供宿主侧语法验证（fakeroot 会拦截 nft 的 netlink 调用）
if [ -n "$NFT_CHECK_DIR" ]; then
    mkdir -p "$NFT_CHECK_DIR"
    cp rootfs/etc/nftables.nft "$NFT_CHECK_DIR/" 2>/dev/null || true
    cp rootfs/etc/nftables.d/*.nft "$NFT_CHECK_DIR/" 2>/dev/null || true
fi

truncate -s 2G "$OUT_EXT4"
mkfs.ext4 -q -F -L alpine-rootfs -d rootfs "$OUT_EXT4"
echo "[assemble-rootfs] 完成"
