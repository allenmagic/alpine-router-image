#!/usr/bin/env bash
# ============================================================
# 路由 VM 专用内核构建（x86_64 / cloud-hypervisor guest）
#
# 本内核对应 router.nix 的 `microvm.router.kernel = "custom"`；官方三件套
# 对应 "alpine"。两者并存，rootfs 同时携带双方的 /lib/modules/<ver>（目录名
# 不同故互不干扰），由启动内核的 uname -r 决定命中哪一份。
#
# 相对 Alpine 官方 virt 三件套的差异：
#   - 引导链全 builtin（ext4/virtio_blk/virtio_net…）→ 不需要 initramfs 注入
#     ext4 依赖链；但 microvm.nix 五个 runner 均无条件传 --initramfs（main 与
#     当前 pin 零差异），故仍产一个空 cpio 占位，内核 rdinit 找不到 /init 后
#     "ignoring" 继续挂 root=/dev/vda（CH v53 实测）
#   - 不产 modloop：rootfs 无需为本内核做 unsquashfs + 依赖闭包拷贝
#   - 同时产出 bzImage 与 vmlinux（ELF）：CH 的 x86_64 分支取
#     ${kernel.dev}/vmlinux，当前喂 bzImage 由 CH 按文件头识别；vmlinux 是
#     将来切 PVH 的零成本后路（它本就是 bzImage 的前置产物），故构建但不发布
#
# 版本策略：只跟最新 LTS（路由器要的是不断网，而非新特性；LTS 只收 backport
# 修复，回归面窄）。bump 时同步改 KVER 与 SRC_SHA256，CI 会重建配套 rootfs。
#
# 用法:
#   kernel/build.sh                       # 完整构建到 kernel/out/
#   kernel/build.sh --config-only         # 只生成并校验 .config（CI 快速门禁）
#   KVER=6.18.48 kernel/build.sh          # 覆盖版本
#   JOBS=8 kernel/build.sh                # 覆盖并行度
#
# 依赖: gcc make bc bison flex libelf openssl(dev) perl xz curl
# ============================================================
set -euo pipefail

KVER="${KVER:-6.18.48}"
JOBS="${JOBS:-$(nproc)}"
CONFIG_ONLY=0
[ "${1:-}" = "--config-only" ] && CONFIG_ONLY=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="$SCRIPT_DIR/config.fragment"
OUT_DIR="$SCRIPT_DIR/out"
CACHE_DIR="${KERNEL_CACHE_DIR:-$SCRIPT_DIR/.cache}"

# 源码校验和：升级 KVER 时同步更新（值取自 kernel.org 的 sha256sums.asc）
declare -A SRC_SHA256=(
    [6.18.48]="5ebdadb10a4b5708fc6b1c457764a110bc49f8150cc3502c59b921ead8c6fc8c"
)

log() { printf '[kernel] %s\n' "$*" >&2; }
die() { printf '[kernel] 错误: %s\n' "$*" >&2; exit 1; }

MAJOR="v${KVER%%.*}.x"
TARBALL="linux-${KVER}.tar.xz"
SRC_DIR="$CACHE_DIR/linux-${KVER}"

# ---------- 1. 取源码 ----------
mkdir -p "$CACHE_DIR"
if [ ! -d "$SRC_DIR" ]; then
    if [ ! -f "$CACHE_DIR/$TARBALL" ]; then
        log "下载 $TARBALL ..."
        # 镜像优先（国内可用），失败回落 kernel.org
        for base in \
            "https://mirrors.ustc.edu.cn/kernel.org/linux/kernel/$MAJOR" \
            "https://mirrors.tuna.tsinghua.edu.cn/kernel/$MAJOR" \
            "https://cdn.kernel.org/pub/linux/kernel/$MAJOR"
        do
            if curl -fsSL --max-time 900 -o "$CACHE_DIR/$TARBALL.part" "$base/$TARBALL"; then
                mv "$CACHE_DIR/$TARBALL.part" "$CACHE_DIR/$TARBALL"
                log "下载完成（源: $base）"
                break
            fi
            log "镜像失败，尝试下一个: $base"
        done
        [ -f "$CACHE_DIR/$TARBALL" ] || die "所有镜像均下载失败"
    fi

    # 校验（未登记版本时打印实际值供登记，不静默通过）
    want="${SRC_SHA256[$KVER]:-}"
    got="$(sha256sum "$CACHE_DIR/$TARBALL" | cut -d' ' -f1)"
    if [ -z "$want" ]; then
        die "KVER=$KVER 未登记 sha256。实际值: $got（登记到 build.sh 的 SRC_SHA256 后重试）"
    fi
    [ "$want" = "$got" ] || die "源码 sha256 不符：期望 $want，实际 $got"
    log "源码校验通过"

    log "解压 ..."
    mkdir -p "$SRC_DIR"
    tar xf "$CACHE_DIR/$TARBALL" -C "$SRC_DIR" --strip-components=1
fi

# ---------- 2. 生成 .config 并逐条校验片段生效 ----------
BUILD_DIR="$CACHE_DIR/build-${KVER}"
mkdir -p "$BUILD_DIR"

log "生成 .config（allnoconfig + 片段）..."
# allnoconfig：片段外一律 n；再 olddefconfig 补齐 select 出来的新符号默认值
KCONFIG_ALLCONFIG="$FRAGMENT" make -C "$SRC_DIR" O="$BUILD_DIR" allnoconfig >/dev/null
make -C "$SRC_DIR" O="$BUILD_DIR" olddefconfig >/dev/null

# 片段静默失效 = 能编译但不可引导（曾漏掉 BLK_DEV → 无 virtio_blk → 无根盘）
log "校验片段生效 ..."
python3 "$SCRIPT_DIR/verify-config.py" "$FRAGMENT" "$BUILD_DIR/.config" \
    || die "config 片段校验失败（见上方清单）"

if [ "$CONFIG_ONLY" -eq 1 ]; then
    log "--config-only：已生成并校验 $BUILD_DIR/.config"
    exit 0
fi

# ---------- 3. 编译 ----------
log "编译（-j$JOBS）..."
make -C "$SRC_DIR" O="$BUILD_DIR" -j"$JOBS" bzImage vmlinux

# ---------- 4. 产物 ----------
# 产物名不带版本。custom 只有一个变体（跟最新 LTS），而 release tag
# （microvm-router-vm-YYYYMMDD）已经承担了版本区分——把内核版本写进资产名
# 会让每次 point release bump 都要手改 router.nix 的 url，
# sync-flake-sha.py 的锚定正则也会失配。版本可从 config-router 内容与
# guest 的 uname -r 查得，rootfs 里的 /lib/modules/<版本串> 也仍带版本。
KREL="$(make -C "$SRC_DIR" O="$BUILD_DIR" -s kernelrelease)"
log "内核版本串: $KREL"

mkdir -p "$OUT_DIR"
cp "$BUILD_DIR/arch/x86/boot/bzImage" "$OUT_DIR/vmlinuz-router"
cp "$BUILD_DIR/vmlinux" "$OUT_DIR/vmlinux-router"
cp "$BUILD_DIR/.config" "$OUT_DIR/config-router"

# ---------- 5. 模块元数据 ----------
# 本配置 0 个 =m，`modules_install` 会因缺 modules.order 直接失败（此前被
# `|| true` 吞掉，产出 0 文件）。引导链全 builtin 不需要 .ko，但仍必须给
# rootfs 一份 /lib/modules/$KREL 元数据，否则 modprobe 报
#   FATAL: Module nf_tables not found in directory /lib/modules/$KREL
# 而 openrc 的 modules 服务用 `modprobe -q` 且在 while 管道里丢弃返回码，
# 于是照样打印 [ ok ] —— 失败完全静默。
# depmod 只需 modules.builtin + modules.builtin.modinfo 即可生成
# modules.builtin.bin / modules.builtin.alias.bin（modprobe 判定 builtin 的
# 索引），产物约 108K。缺 modules.order 只是一条 warning。
# 实测：运行时真正必需的只有 modules.builtin.bin（2954 字节），且 modprobe
# 只认 basename、不校验路径。仍装全套——挑装要自行判断哪些运行时必需，而
# 108K 对 155M 镜像是 0.07%，省下的 105K 换不来任何东西。
rm -rf "$OUT_DIR/modules"
MODDIR="$OUT_DIR/modules/lib/modules/$KREL"
mkdir -p "$MODDIR"
cp "$BUILD_DIR/modules.builtin" "$BUILD_DIR/modules.builtin.modinfo" "$MODDIR/"
depmod -b "$OUT_DIR/modules" "$KREL" 2>/dev/null
[ -f "$MODDIR/modules.builtin.bin" ] || die "depmod 未生成 modules.builtin.bin"
log "模块元数据: $(du -sh "$MODDIR" | cut -f1)（builtin 项 $(wc -l < "$MODDIR/modules.builtin") 个，0 个 .ko）"

# ---------- 6. 空 initramfs 占位 ----------
# 本内核引导链全 builtin，不需要 initramfs。但 microvm.nix 的五个 runner
# （cloud-hypervisor/qemu/firecracker/crosvm/stratovirt）都把 --initramfs 放在
# 无条件参数里，且 initrdPath 是 types.path 无 null 分支——声明侧无法不传。
# 故产一个空 cpio：内核挂载后找不到 /init，打印
#   check access for rdinit=/init failed: -2, ignoring
# 随后正常走 root=/dev/vda（CH v53 本地实测）。这样五个 runner 全部适用，
# 上游一行不用改；将来上游把 --initramfs 改成条件项后可直接弃用本产物。
#
# 未压缩：内核原生支持未压缩 cpio（无需任何 CONFIG_RD_* 解压器），而 gzip 需要
# CONFIG_RD_GZIP=y 即 zlib 依赖——为解压 50 字节空文件增加内核体积违背 router
# 变体的精简原则。512 字节 vs 50 字节对传输/存储影响可忽略。
: | cpio --null -o --format=newc 2>/dev/null > "$OUT_DIR/initramfs-empty.cpio"
log "空 initramfs: $(stat -c%s "$OUT_DIR/initramfs-empty.cpio") 字节（Alpine initrd 参照: 10.3M）"

# vmlinux 不入 SHA256SUMS：当前 CH 走 bzImage 路径不消费它，它只是将来切 PVH
# 的后路与宿主侧 gdb/crash 的符号来源，无需作为 release 资产发布
(cd "$OUT_DIR" && sha256sum vmlinuz-router config-router initramfs-empty.cpio > SHA256SUMS)

log "完成："
ls -la "$OUT_DIR"
log "bzImage: $(du -h "$OUT_DIR/vmlinuz-router" | cut -f1)（Alpine vmlinuz-virt 参照: 12M）"
