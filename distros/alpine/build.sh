#!/usr/bin/env bash
#
# distros/alpine/build.sh —— 构建 Alpine x86_64 rootfs
# 从 dl-cdn.alpinelinux.org 下载 minirootfs tarball 并 chroot 配置
# 产物落在仓库内 build/alpine/（被 .gitignore 排除）
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"     # → distros/alpine
REPO_ROOT="$(readlink -f "${SCRIPT_DIR}/../..")"  # → 仓库根

# ---------- 加载 .env（如果存在）----------
if [ -f "${REPO_ROOT}/.env" ]; then
    echo "[alpine] 加载 ${REPO_ROOT}/.env ..."
    set -a  # 自动 export 所有变量
    source "${REPO_ROOT}/.env"
    set +a
fi

source "${REPO_ROOT}/lib/chroot-helper.sh"

# ---------- 可配置参数 ----------
DISTRO="alpine"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build}"
BUILD_BASE="${BUILD_BASE:-${BUILD_ROOT}/${DISTRO}}"
ROOTFS="${ROOTFS:-${BUILD_BASE}/alpine-rootfs}"
CACHE_DIR="${CACHE_DIR:-${BUILD_BASE}/cache}"
MIRROR="${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ARCH="x86_64"        # VM 场景固定架构（r3s 的多架构映射已移除）
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
HOSTNAME_VAL="${HOSTNAME_VAL:-alpine-router}"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"
PACK="${PACK:-0}"                                            # 1=构建后顺带打包

# ---------- 镜像源映射 ----------
declare -A MIRRORS
MIRRORS["default"]="https://dl-cdn.alpinelinux.org/alpine"
MIRRORS["aliyun"]="https://mirrors.aliyun.com/alpine"
MIRRORS["tuna"]="https://mirrors.tuna.tsinghua.edu.cn/alpine"
MIRRORS["tsinghua"]="https://mirrors.tuna.tsinghua.edu.cn/alpine"

_REPO_IN="${REPO:-default}"
if [[ "${_REPO_IN}" =~ ^https?:// ]]; then
    MIRROR="${_REPO_IN}"
else
    MIRROR="${MIRRORS[${_REPO_IN}]:-${MIRRORS[default]}}"
fi
unset _REPO_IN

# ---------- 路径准备 ----------
BUILD_ROOT="$(readlink -m "${BUILD_ROOT}")"
BUILD_BASE="$(readlink -m "${BUILD_BASE}")"
ROOTFS="$(readlink -m "${ROOTFS}")"
CACHE_DIR="$(readlink -m "${CACHE_DIR}")"
WORKDIR="$(dirname "${ROOTFS}")"

# ---------- 提权前：创建构建目录树（属主归调用者） ----------
mkdir -p "${BUILD_BASE}" "${CACHE_DIR}" "${WORKDIR}"

# ---------- 权限 ----------
[ "${EUID}" -eq 0 ] || exec sudo -E "$0" "$@"

[ -f "${SETUP_SCRIPT}" ] || { echo "缺少 ${SETUP_SCRIPT}" >&2; exit 1; }

# 护栏
case "${WORKDIR}" in
    /|/tmp|/var/tmp|/home|/root|/usr|/etc)
        echo "错误：构建工作区不能是共享系统目录 (${WORKDIR})。" >&2
        exit 1 ;;
esac

# 架构固定 x86_64：宿主与目标同构，无需 binfmt/qemu 预检
echo "[alpine] 架构：${ARCH}（宿主 $(uname -m)，同构原生构建）"

# ---------- 第一步：下载 alpine-minirootfs ----------
echo "[alpine] 1. 解析最新 minirootfs 版本 ..."
BASE_URL="${MIRROR}/latest-stable/releases/${ARCH}"
LATEST_YAML="$(wget -qO- "${BASE_URL}/latest-releases.yaml" 2>/dev/null || true)"
FILENAME="$(echo "${LATEST_YAML}" | grep -oE 'alpine-minirootfs-[0-9.]+-'"${ARCH}"'\.tar\.gz' | head -n1)"
[ -n "${FILENAME}" ] || { echo "错误：无法解析 minirootfs 文件名" >&2; exit 1; }
echo "[alpine]   最新: ${FILENAME}"

TARBALL="${CACHE_DIR}/${FILENAME}"

if [ ! -f "${TARBALL}" ]; then
    echo "[alpine]   下载 ${BASE_URL}/${FILENAME} ..."
    wget -t 3 -T 30 -nv -O "${TARBALL}" "${BASE_URL}/${FILENAME}" || { echo "[alpine]   错误：下载失败，可尝试换镜像源 REPO=tuna" >&2; exit 1; }
    wget -qO "${TARBALL}.sha256" "${BASE_URL}/${FILENAME}.sha256" 2>/dev/null || true
    if [ -f "${TARBALL}.sha256" ]; then
        (cd "${CACHE_DIR}" && sha256sum -c "${FILENAME}.sha256" 2>/dev/null) || echo "[alpine]   警告：sha256 校验跳过" >&2
    fi
else
    echo "[alpine]   缓存命中: ${TARBALL}"
fi

# ---------- 第二步：解压到 rootfs ----------
echo "[alpine] 2. 解压到 ${ROOTFS} ..."
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"
tar xzf "${TARBALL}" --numeric-owner --same-owner -C "${ROOTFS}" 2>/dev/null || \
    tar xzf "${TARBALL}" -C "${ROOTFS}"

[ -x "${ROOTFS}/bin/busybox" ] || { echo "rootfs 解压异常" >&2; exit 1; }

# ---------- 第三步：chroot ----------
echo "[alpine] 3. 进入 chroot ..."
trap 'chroot_exit "${ROOTFS}"' EXIT
chroot_enter "${ROOTFS}"

# ---------- 第三+步：拷贝安装框架 ----------
echo "[alpine] 3+. 拷贝安装框架到 rootfs ..."
cp -f "${REPO_ROOT}/lib/download-helpers.sh" "${ROOTFS}/download-helpers.sh"
cp -r "${REPO_ROOT}/base" "${ROOTFS}/base"
cp -r "${REPO_ROOT}/scripts" "${ROOTFS}/scripts"
cp -f "${SCRIPT_DIR}/package.list" "${ROOTFS}/package.list"
cp -f "${SCRIPT_DIR}/service.sh" "${ROOTFS}/service.sh"
cp -f "${SCRIPT_DIR}/network.sh" "${ROOTFS}/network.sh"
cp -f "${SCRIPT_DIR}/check.sh" "${ROOTFS}/check.sh"
cp -f "${REPO_ROOT}/network.env" "${ROOTFS}/network.env"

# ---------- 第四步：安装基础系统（openrc + 软件源）----------
echo "[alpine] 4. 安装基础系统 ..."
chroot_run "${ROOTFS}" /bin/sh << CHROOTEOF
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -e

# 配置软件源
echo "${MIRROR}/latest-stable/main" > /etc/apk/repositories
echo "${MIRROR}/latest-stable/community" >> /etc/apk/repositories

# 安装 openrc（不装 alpine-base，避免触发 setup-alpine）
apk add --no-cache openrc

CHROOTEOF

# ---------- 第五步：执行 setup ----------
echo "[alpine] 5. 执行 setup（安装包 / 配置 / 服务）..."
cp -f "${SETUP_SCRIPT}" "${ROOTFS}/setup.sh"
chmod +x "${ROOTFS}/setup.sh"
chroot_run "${ROOTFS}" /usr/bin/env \
    DISTRO="${DISTRO}" \
    ROOT_PASSWORD="${ROOT_PASSWORD}" \
    HOSTNAME_VAL="${HOSTNAME_VAL}" \
    MIRROR="${MIRROR}" \
    /bin/sh /setup.sh
rm -f "${ROOTFS}/setup.sh"
rm -f "${ROOTFS}/download-helpers.sh"
rm -f "${ROOTFS}/package.list"
rm -f "${ROOTFS}/service.sh"
rm -f "${ROOTFS}/network.sh"
rm -f "${ROOTFS}/check.sh"
rm -f "${ROOTFS}/network.env"

echo "[alpine] base rootfs 构建完成：${ROOTFS}"

# ---------- 可选：打包 ----------
if [[ "${PACK}" == "1" ]]; then
    chroot_exit "${ROOTFS}"
    trap '' EXIT
    OUTPUT="${OUTPUT:-${ROOTFS%/}-minimal.tar.xz}"
    OUTPUT="$(readlink -m "${OUTPUT}")"
    echo "[alpine] 6. 调用打包：lib/slim-rootfs.sh"
    "${REPO_ROOT}/lib/slim-rootfs.sh" "${ROOTFS}" "${OUTPUT}"
fi
