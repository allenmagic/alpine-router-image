#!/usr/bin/env bash
#
# distros/gentoo/build.sh —— 构建 Gentoo rootfs（VM 场景默认 x86_64）
# 从 Gentoo distfiles 下载 stage3-<arch>-musl-openrc tarball 作为构建环境，
# 在其中用 ROOT= emerge 安装包到干净的目标 rootfs
# 产物落在仓库内 build/gentoo/（被 .gitignore 排除）
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"     # → distros/gentoo
REPO_ROOT="$(readlink -f "${SCRIPT_DIR}/../..")"  # → 仓库根

# ---------- 加载 .env（如果存在）----------
if [ -f "${REPO_ROOT}/.env" ]; then
    echo "[gentoo] 加载 ${REPO_ROOT}/.env ..."
    set -a  # 自动 export 所有变量
    source "${REPO_ROOT}/.env"
    set +a
fi

source "${REPO_ROOT}/lib/chroot-helper.sh"

# ---------- 可配置参数 ----------
DISTRO="gentoo"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build}"
BUILD_BASE="${BUILD_BASE:-${BUILD_ROOT}/${DISTRO}}"
STAGE3_DIR="${STAGE3_DIR:-${BUILD_BASE}/stage3}"         # stage3 解压目录（构建环境）
ROOTFS="${ROOTFS:-${BUILD_BASE}/gentoo-rootfs}"         # 最终产物目录（轻量 rootfs）
CACHE_DIR="${CACHE_DIR:-${BUILD_BASE}/cache}"
ARCH="x86_64"        # VM 场景固定架构（r3s 的多架构映射已移除）
GENTOO_ARCH="amd64"  # stage3 路径与镜像目录使用

MIRROR="${MIRROR:-https://distfiles.gentoo.org/releases/${GENTOO_ARCH}/autobuilds}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
HOSTNAME_VAL="${HOSTNAME_VAL:-alpine-router}"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"
PACK="${PACK:-0}"

# ---------- 镜像源映射 ----------
declare -A MIRRORS
MIRRORS["default"]="https://distfiles.gentoo.org/releases/${GENTOO_ARCH}/autobuilds"
MIRRORS["tuna"]="https://mirrors.tuna.tsinghua.edu.cn/gentoo/releases/${GENTOO_ARCH}/autobuilds"
MIRRORS["tsinghua"]="https://mirrors.tuna.tsinghua.edu.cn/gentoo/releases/${GENTOO_ARCH}/autobuilds"

_REPO_IN="${REPO:-default}"
if [[ "${_REPO_IN}" =~ ^https?:// ]]; then
    MIRROR="${_REPO_IN}"
else
    MIRROR="${MIRRORS[${_REPO_IN}]:-${MIRRORS[default]}}"
fi
unset _REPO_IN

# ---------- 解析 Gentoo 镜像 base URL（用于 emerge 时的 distfiles）----------
GENTOO_MIRROR_BASE="https://distfiles.gentoo.org"
case "${REPO:-default}" in
    tuna|tsinghua)
        GENTOO_MIRROR_BASE="https://mirrors.tuna.tsinghua.edu.cn/gentoo"
        ;;
esac

# ---------- 路径准备 ----------
BUILD_ROOT="$(readlink -m "${BUILD_ROOT}")"
BUILD_BASE="$(readlink -m "${BUILD_BASE}")"
STAGE3_DIR="$(readlink -m "${STAGE3_DIR}")"
ROOTFS="$(readlink -m "${ROOTFS}")"
CACHE_DIR="$(readlink -m "${CACHE_DIR}")"
WORKDIR="$(dirname "${STAGE3_DIR}")"

[ -f "${SETUP_SCRIPT}" ] || { echo "缺少 ${SETUP_SCRIPT}" >&2; exit 1; }

# 护栏
case "${WORKDIR}" in
    /|/tmp|/var/tmp|/home|/root|/usr|/etc)
        echo "错误：构建工作区不能是共享系统目录 (${WORKDIR})。" >&2
        exit 1 ;;
esac

# ---------- 创建构建目录树（普通用户，方便清理）----------
mkdir -p "${BUILD_BASE}" "${CACHE_DIR}" "${WORKDIR}"

# 架构固定 x86_64：宿主与目标同构，无需 binfmt/qemu 预检
echo "[gentoo] 架构：${ARCH}（宿主 $(uname -m)，同构原生构建）"

# ---------- 第一步：下载 stage3-<arch>-openrc ----------
# GENTOO_ARCH 已在参数区定义（固定 amd64）
echo "[gentoo] 1. 解析最新 stage3-${GENTOO_ARCH}-musl-openrc 版本 ..."
LATEST_TXT="$(wget -t 2 -T 30 -qO- "${MIRROR}/latest-stage3-${GENTOO_ARCH}-musl-openrc.txt" 2>/dev/null || true)"
if [ -z "${LATEST_TXT}" ]; then
    echo "错误：无法下载 ${MIRROR}/latest-stage3-${GENTOO_ARCH}-musl-openrc.txt" >&2
    echo "请检查网络连接或尝试切换镜像源（REPO=default 使用官方源）" >&2
    exit 1
fi
# 过滤掉注释和空行，提取第一个文件路径
FILENAME="$(echo "${LATEST_TXT}" | grep -v '^#' | grep -v '^$' | grep '\.tar' | awk '{print $1}' | head -n1)"
if [ -z "${FILENAME}" ]; then
    echo "错误：无法解析 stage3 文件名" >&2
    echo "下载的内容：" >&2
    echo "${LATEST_TXT}" | head -5 >&2
    exit 1
fi
BASENAME="$(basename "${FILENAME}")"
echo "[gentoo]   最新: ${BASENAME}"

TARBALL="${CACHE_DIR}/${BASENAME}"

if [ ! -f "${TARBALL}" ]; then
    echo "[gentoo]   下载 ${MIRROR}/${FILENAME} ..."
    wget -t 3 -T 60 -nv -O "${TARBALL}" "${MIRROR}/${FILENAME}" || { echo "[gentoo]   错误：下载失败，可尝试换镜像源 REPO=tuna" >&2; exit 1; }
    # 下载签名文件（可选校验）
    wget -qO "${TARBALL}.DIGESTS" "${MIRROR}/${FILENAME}.DIGESTS" 2>/dev/null || true
    if [ -f "${TARBALL}.DIGESTS" ]; then
        echo "[gentoo]   校验 SHA512 ..."
        if ! (cd "${CACHE_DIR}" && grep -A1 SHA512 "${TARBALL}.DIGESTS" | grep "${BASENAME}" | sha512sum -c - 2>/dev/null); then
            echo "[gentoo]   警告：SHA512 校验不匹配，tarball 可能损坏" >&2
        fi
    fi
else
    echo "[gentoo]   缓存命中: ${TARBALL}"
    # 缓存文件快速完整性检查
    if ! xz -t "${TARBALL}" 2>/dev/null; then
        echo "[gentoo]   缓存 tarball 损坏，重新下载 ..." >&2
        rm -f "${TARBALL}" "${TARBALL}.DIGESTS"
        wget -t 3 -T 60 -nv -O "${TARBALL}" "${MIRROR}/${FILENAME}" || { echo "[gentoo]   错误：下载失败" >&2; exit 1; }
    fi
fi

# ---------- 权限检查：解压 stage3 需要 root ----------
[ "${EUID}" -eq 0 ] || exec sudo -E "$0" "$@"

# ---------- 第二步：解压 stage3 到构建环境 ----------
echo "[gentoo] 2. 解压 stage3 到 ${STAGE3_DIR} ..."
rm -rf "${STAGE3_DIR}"
mkdir -p "${STAGE3_DIR}"
# 先做完整性校验（失败则清缓存重试）
if ! xz -t "${TARBALL}" 2>/dev/null; then
    echo "[gentoo]   tarball 完整性校验失败，清除缓存后重试 ..." >&2
    rm -f "${TARBALL}" "${TARBALL}.DIGESTS"
    wget -t 3 -T 60 -nv -O "${TARBALL}" "${MIRROR}/${FILENAME}" || { echo "[gentoo]   错误：重试下载仍失败" >&2; exit 1; }
fi
if ! tar xpf "${TARBALL}" --numeric-owner --xattrs-include='*.*' --same-owner -C "${STAGE3_DIR}"; then
    echo "[gentoo]   带 xattrs 解压失败，清理后降级解压 ..."
    rm -rf "${STAGE3_DIR}"
    mkdir -p "${STAGE3_DIR}"
    tar xpf "${TARBALL}" -C "${STAGE3_DIR}"
fi

[ -x "${STAGE3_DIR}/bin/busybox" ] || [ -x "${STAGE3_DIR}/usr/bin/emerge" ] || { echo "stage3 解压异常" >&2; exit 1; }

# ---------- 第三步：chroot 进入 stage3 ----------
echo "[gentoo] 3. 进入 stage3 chroot ..."
trap 'chroot_exit "${STAGE3_DIR}"' EXIT
chroot_enter "${STAGE3_DIR}"

# ---------- 第三+步：拷贝安装框架到 stage3 ----------
echo "[gentoo] 3+. 拷贝安装框架到 stage3 ..."
cp -f "${REPO_ROOT}/lib/download-helpers.sh" "${STAGE3_DIR}/download-helpers.sh"
cp -r "${REPO_ROOT}/base" "${STAGE3_DIR}/base"
cp -r "${REPO_ROOT}/scripts" "${STAGE3_DIR}/scripts"
cp -f "${SCRIPT_DIR}/package.list" "${STAGE3_DIR}/package.list"
	cp -f "${SCRIPT_DIR}/service.sh" "${STAGE3_DIR}/service.sh"
	cp -f "${SCRIPT_DIR}/network.sh" "${STAGE3_DIR}/network.sh"
	cp -f "${SCRIPT_DIR}/check.sh" "${STAGE3_DIR}/check.sh"
	cp -f "${REPO_ROOT}/network.env" "${STAGE3_DIR}/network.env"
# ---------- 第四+五步：执行 setup（在 stage3 内，安装到 /gentoo-rootfs）----------
echo "[gentoo] 4+5. 执行 setup（用 ROOT= emerge 安装到目标 rootfs）..."
cp -f "${SETUP_SCRIPT}" "${STAGE3_DIR}/setup.sh"
chmod +x "${STAGE3_DIR}/setup.sh"
chroot_run "${STAGE3_DIR}" /usr/bin/env \
    DISTRO="${DISTRO}" \
    ROOT_PASSWORD="${ROOT_PASSWORD}" \
    HOSTNAME_VAL="${HOSTNAME_VAL}" \
    TARGET_ROOTFS="/gentoo-rootfs" \
    GENTOO_MIRROR_BASE="${GENTOO_MIRROR_BASE}" \
    HOST_ARCH="${HOST_ARCH}" \
    ARCH="${ARCH}" \
    SCRIPT_DIR="/" \
    /bin/sh /setup.sh

# setup.sh 在 stage3 内生成了 /gentoo-rootfs，现在把它移出来
echo "[gentoo] 6. 移出目标 rootfs ..."
# 安全护栏：拒绝系统目录
case "${ROOTFS}" in
    /|/tmp|/var/tmp|/home|/root|/usr|/etc)
        echo "错误：rootfs 目标不能是共享系统目录 (${ROOTFS})。" >&2
        exit 1 ;;
esac
rm -rf "${ROOTFS}"
mv "${STAGE3_DIR}/gentoo-rootfs" "${ROOTFS}"

rm -f "${STAGE3_DIR}/setup.sh"
rm -f "${STAGE3_DIR}/download-helpers.sh"
rm -f "${STAGE3_DIR}/package.list"
rm -f "${STAGE3_DIR}/service.sh"
rm -f "${STAGE3_DIR}/network.sh"
rm -f "${STAGE3_DIR}/check.sh"
rm -f "${STAGE3_DIR}/network.env"


echo "[gentoo] base rootfs 构建完成：${ROOTFS}"

# ---------- 可选：打包 ----------
if [[ "${PACK}" == "1" ]]; then
    chroot_exit "${STAGE3_DIR}"
    trap '' EXIT
    OUTPUT="${OUTPUT:-${ROOTFS%/}-minimal.tar.xz}"
    OUTPUT="$(readlink -m "${OUTPUT}")"
    echo "[gentoo] 7. 调用打包：lib/slim-rootfs.sh"
    "${REPO_ROOT}/lib/slim-rootfs.sh" "${ROOTFS}" "${OUTPUT}"
fi


