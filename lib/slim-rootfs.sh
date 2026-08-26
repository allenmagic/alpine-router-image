#!/usr/bin/env bash
#
# lib/slim-rootfs.sh —— 通用 rootfs 精简与打包工具
#
# 功能：
#   1. 删除国际化语言包 / 帮助文档（locale / i18n / man / doc）
#   2. 清空包管理器缓存（自动适配 xbps / apt / apk）
#   3. strip 二进制调试符号（仅 ELF，排除静态库 .a/.o；按 rootfs 目标架构自动选 strip）
#   4. 统计精简后体积
#   5. 删除旧包后用 xz 极限压缩打包（-9e -T0 多线程）
#   6. 输出结果到 GitHub Actions（$GITHUB_OUTPUT / $GITHUB_STEP_SUMMARY）
#
# 用法：
#   sudo ./lib/slim-rootfs.sh <rootfs目录> [输出文件名]
#   sudo STRIP=aarch64-linux-gnu-strip ./lib/slim-rootfs.sh ./void-rootfs out.tar.xz
#
# 架构识别 / strip 工具选择委托 lib/arch-detect.sh。
set -euo pipefail

# ---------- 依赖：架构识别函数库（同目录定位）----------
_SLIM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=arch-detect.sh
. "${_SLIM_LIB_DIR}/arch-detect.sh"

# ---------- 可配置参数 ----------
ROOTFS="${1:-rootfs}"                              # rootfs 目录
OUTPUT="${2:-${ROOTFS%/}-minimal.tar.xz}"          # 输出文件名（默认 <rootfs>-minimal.tar.xz）
XZ_LEVEL="${XZ_LEVEL:--9e -T0}"                    # xz 压缩参数（-T0 多线程）
KEEP_PKG_DB="${KEEP_PKG_DB:-0}"                    # 1=保留包数据库（仍可在镜像内装卸软件包）

# ---------- 权限：非 root 自动 sudo 重入 ----------
if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "==> 当前非 root，使用 sudo 重新执行 ..."
        exec sudo -E "$0" "$@"
    else
        echo "错误：需要 root 权限且系统无 sudo。" >&2
        exit 1
    fi
fi

# ---------- 前置检查 ----------
if [[ ! -d "${ROOTFS}" ]]; then
    echo "错误：rootfs 目录不存在：${ROOTFS}" >&2
    exit 1
fi

ROOTFS_ABS="$(readlink -f "${ROOTFS}")"
if [[ "${ROOTFS_ABS}" == "/" || -z "${ROOTFS_ABS}" ]]; then
    echo "错误：拒绝对根目录或空路径执行操作。" >&2
    exit 1
fi

# 安全护栏：rootfs 内不应残留挂载点（避免误删/误打包宿主内容）
if mount | grep -q " ${ROOTFS_ABS}/"; then
    echo "错误：检测到 ${ROOTFS_ABS} 下仍有挂载点，请先 chroot_exit / umount。" >&2
    mount | grep " ${ROOTFS_ABS}/" >&2 || true
    exit 1
fi

# ---------- 架构 & strip 工具选择（委托 arch-detect）----------
HOST_ARCH="$(arch_host)"
TARGET_ARCH="$(arch_of_rootfs "${ROOTFS_ABS}")"   # 探测不到回传空串

# strip 命令：用户显式 STRIP 优先；否则按目标架构自动选
if [[ -z "${STRIP:-}" ]]; then
    if [[ -n "${TARGET_ARCH}" ]]; then
        STRIP="$(arch_strip_cmd "${TARGET_ARCH}")"
    else
        # 目标架构未知：退回本机 strip（保守）
        STRIP="strip"
    fi
fi

# strip 工具存在性检查（缺失则跳过第 3 步而非中断）
HAS_STRIP=1
if ! command -v "${STRIP}" >/dev/null 2>&1; then
    echo "警告：未找到 ${STRIP}，将跳过 strip 步骤。" >&2
    HAS_STRIP=0
fi

# 跨架构 strip 有效性提示（委托 arch-detect 判断）
if [[ "${HAS_STRIP}" -eq 1 && -n "${TARGET_ARCH}" ]] \
   && ! arch_strip_effective "${STRIP}" "${TARGET_ARCH}"; then
    echo "提示：跨架构构建（${HOST_ARCH} → ${TARGET_ARCH}）但仅有本机 strip，strip 对目标 ELF 可能无效（体积不会减小）。" >&2
    echo "      本地若要真正生效：apt-get install binutils-${TARGET_ARCH}-linux-gnu（或安装 llvm）。" >&2
    echo "      CI 在原生 ${TARGET_ARCH} runner 上则无此问题。" >&2
fi

# file 命令检查（用于精确识别 ELF，缺失则降级）
HAS_FILE=1
if ! command -v file >/dev/null 2>&1; then
    echo "提示：未找到 file 命令，strip 不做 ELF 过滤（仍排除 .a/.o）。" >&2
    HAS_FILE=0
fi

# xz 检查（打包必需）
if ! command -v xz >/dev/null 2>&1; then
    echo "错误：未找到 xz，请安装 xz-utils。" >&2
    exit 1
fi

echo "==> 主机架构：  ${HOST_ARCH}"
echo "==> 目标架构：  ${TARGET_ARCH:-未知}"
echo "==> strip 工具：${STRIP}"
echo "==> 目标 rootfs：${ROOTFS_ABS}"
echo "==> 输出文件：  ${OUTPUT}"
echo "==> 处理前大小：$(du -sh "${ROOTFS_ABS}" | cut -f1)"
echo

# ---------- 1. 删除国际化语言包和帮助文档 ----------
echo "[1/6] 删除 locale / i18n / man / doc ..."
rm -rf "${ROOTFS_ABS}/usr/share/locale/"* \
       "${ROOTFS_ABS}/usr/share/i18n/"*   \
       "${ROOTFS_ABS}/usr/share/man/"*    \
       "${ROOTFS_ABS}/usr/share/doc/"*    \
       2>/dev/null || true

# ---------- 2. 清空包管理器缓存（自动适配多发行版） ----------
echo "[2/6] 清空包管理器缓存 ..."
# xbps (Void)
rm -rf "${ROOTFS_ABS}/var/cache/xbps/"* 2>/dev/null || true
# apt (Debian/Devuan)
rm -rf "${ROOTFS_ABS}/var/cache/apt/archives/"*.deb 2>/dev/null || true
rm -rf "${ROOTFS_ABS}/var/lib/apt/lists/"*          2>/dev/null || true
# apk (Alpine)
rm -rf "${ROOTFS_ABS}/var/cache/apk/"* 2>/dev/null || true

# 包数据库：默认清空以省体积；KEEP_PKG_DB=1 时保留（镜像内仍可装卸软件包）
if [[ "${KEEP_PKG_DB}" -eq 1 ]]; then
    echo "  -> KEEP_PKG_DB=1，保留包数据库。"
else
    echo "  -> 清空包数据库（清后镜像内将无法管理软件包）。"
    rm -rf "${ROOTFS_ABS}/var/lib/xbps/"* 2>/dev/null || true
fi

# ---------- 3. 剥离二进制调试符号（仅 ELF，排除静态库；strip 失败不致命） ----------
if [[ "${HAS_STRIP}" -eq 1 ]]; then
    echo "[3/6] strip 二进制调试符号（较耗时）..."
    # 覆盖常见二进制目录；不存在的目录自动忽略
    STRIP_DIRS=""
    for d in usr/bin usr/sbin usr/lib bin sbin lib; do
        [[ -d "${ROOTFS_ABS}/${d}" ]] && STRIP_DIRS="${STRIP_DIRS} ${ROOTFS_ABS}/${d}"
    done

    if [[ -z "${STRIP_DIRS}" ]]; then
        echo "  -> 未发现可处理的二进制目录，跳过。"
    elif [[ "${HAS_FILE}" -eq 1 ]]; then
        # 稳妥版：file 识别后只处理可执行 ELF / 共享库，排除 .a/.o
        # 注意：每个文件 strip 失败 || true，sh -c 末尾 exit 0，find 整体 || true，
        #       三道兜底确保 strip 失败（如跨架构）不会触发 set -e 静默退出。
        find ${STRIP_DIRS} \
             -type f ! -name '*.a' ! -name '*.o' \
             -exec sh -c '
                 strip_bin="$1"; shift
                 for f; do
                     case "$(file -b "$f")" in
                         *ELF*executable*|*ELF*shared\ object*)
                             "$strip_bin" --strip-unneeded "$f" 2>/dev/null || true
                             ;;
                     esac
                 done
                 exit 0
             ' _ "${STRIP}" {} + || true
    else
        # 降级版：无 file 命令，仍排除静态库，其余直接尝试 strip
        find ${STRIP_DIRS} \
             -type f ! -name '*.a' ! -name '*.o' \
             -exec "${STRIP}" --strip-unneeded {} + 2>/dev/null || true
    fi
    echo "  -> strip 完成（失败项已跳过）。"
else
    echo "[3/6] 跳过 strip 步骤。"
fi

# ---------- 4. 查看清理后大小 ----------
echo "[4/6] 清理后目录大小："
du -sh "${ROOTFS_ABS}"

# ---------- 5. xz 极限压缩打包 ----------
echo "[5/6] 打包压缩中（XZ_OPT=${XZ_LEVEL}）..."
# 输出文件已存在则先删除，避免与旧包混淆 / 重复打包
if [[ -e "${OUTPUT}" ]]; then
    echo "  -> 检测到已存在的 ${OUTPUT}，先删除旧文件。"
    rm -f "${OUTPUT}"
fi
export XZ_OPT="${XZ_LEVEL}"
# --numeric-owner 保证跨主机解压属主一致；-p 保留权限
tar --numeric-owner -cpJf "${OUTPUT}" -C "${ROOTFS_ABS}" .

# ---------- 6. 查看最终包大小 ----------
echo "[6/6] 打包完成："
ls -lh "${OUTPUT}"

# ---------- CI 输出（供后续步骤 / 摘要使用） ----------
OUTPUT_ABS="$(readlink -f "${OUTPUT}")"
OUTPUT_SIZE="$(du -h "${OUTPUT_ABS}" | cut -f1)"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "artifact_path=${OUTPUT_ABS}"
        echo "artifact_size=${OUTPUT_SIZE}"
    } >> "${GITHUB_OUTPUT}"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### rootfs 精简打包结果"
        echo ""
        echo "| 项目 | 值 |"
        echo "|------|----|"
        echo "| 输出文件 | \`${OUTPUT_ABS}\` |"
        echo "| 包大小   | ${OUTPUT_SIZE} |"
        echo "| 主机架构 | ${HOST_ARCH} |"
        echo "| 目标架构 | ${TARGET_ARCH:-未知} |"
        echo "| strip 工具 | ${STRIP} |"
    } >> "${GITHUB_STEP_SUMMARY}"
fi

echo "==> 全部完成。"
