#!/bin/sh
# ============================================================
# Router VM 密钥注入脚本（VM 内以 root 执行）
#
# 配置不再经本脚本部署：全部配置已由 router-image 仓库的
# CI 烙进镜像（出厂即正确），本脚本只负责注入密钥类数据。
#
# 通常由宿主侧 `router-vm-deploy`（systemd 服务或手工命令）调用：
#   上传 tarball（install.sh + lib/）→ 上传可选密钥 env 文件（重命名为 ./env）
#   → 解包后执行本脚本，结束后自动删除 env 文件
#
# 可选环境变量（来自 env 文件，见 env.example）：
#   SSH_PUBLIC_KEY                           SSH 公钥（deploy 通道与日常登录）
#   TAILSCALE_AUTH_KEY / CLOUDFLARED_TOKEN   密钥（不提供则跳过对应功能）
# ============================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# ---- 可选密钥 env 文件（deploy 脚本上传为 ./env）----
if [ -f "${SCRIPT_DIR}/env" ]; then
    echo "[install] 加载 env 文件..."
    . "${SCRIPT_DIR}/env"
fi
# 退出时清理密钥文件
trap 'rm -f "${SCRIPT_DIR}/env"' EXIT

# ---- 预检 ----
[ "$(id -u)" -eq 0 ] || { echo "[install] 必须以 root 执行" >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo "[install] 仅支持 Alpine Linux" >&2; exit 1; }

echo "[install] 开始密钥注入..."

# ---- 密钥注入（Tailscale 自动登录，见 README）----
. "${LIB_DIR}/secrets.sh"
inject_secrets

echo "[install] 完成。Tailscale 已自动触发登录（approve 在 admin 侧处理）"
