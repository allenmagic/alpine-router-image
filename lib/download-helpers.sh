#
# lib/download-helpers.sh —— 下载安装助手
#   被各 OS setup.sh source 使用
#
# 提供函数：
#   _dl_url <url> <binary_name>    —— 下载 URL 到 /usr/local/bin/<binary_name>
#                                     自动解压 .tar.gz/.tgz 并查找二进制
#   _gh_latest_tag <owner/repo>    —— 获取 GitHub 最新 release tag
#
# 用法示例（package.list）：
#   [dl@https://example.com/pkg.tar.gz] binary_name
#

# ============================================================
#  通用 URL 下载助手
# ============================================================
# _dl_url <url> <binary_name>
#   下载 <url> 指向的文件到 ${DESTDIR:-/usr/local/bin}/<binary_name>
#   支持两种格式：
#     - .tar.gz/.tgz：自动解压并查找二进制文件
#     - 其他：直接下载为二进制
#   内置 3 次重试 + 指数退避
#   环境变量 DESTDIR：安装目录前缀（默认 /usr/local/bin）
#   例：DESTDIR=/gentoo-rootfs/usr/local/bin _dl_url <url> <bin>
_dl_url() {
    _url_="$1"
    _bin_="$2"
    _dest_="${DESTDIR:-/usr/local/bin}"
    _tmpdir_="/tmp/dl-$$-${_bin_}"
    _asset_="$(basename "${_url_}")"
    mkdir -p "${_tmpdir_}" "${_dest_}"

    echo "[dl] 下载 ${_bin_} ..."

    # 3 次重试 + 指数退避
    _retry_=3
    while [ "${_retry_}" -gt 0 ]; do
        if curl -fsSL "${_url_}" -o "${_tmpdir_}/${_asset_}" 2>/dev/null; then
            break
        fi
        _retry_=$((_retry_ - 1))
        [ "${_retry_}" -gt 0 ] && sleep "$(( (3 - _retry_) * 2 ))"
    done
    if [ "${_retry_}" -eq 0 ]; then
        echo "[dl] 下载 ${_bin_} 失败" >&2
        rm -rf "${_tmpdir_}"
        return 1
    fi

    case "${_asset_}" in
        *.tar.gz|*.tgz)
            tar xzf "${_tmpdir_}/${_asset_}" -C "${_tmpdir_}"
            if [ -f "${_tmpdir_}/${_bin_}" ]; then
                cp -f "${_tmpdir_}/${_bin_}" "${_dest_}/${_bin_}"
            else
                # tar.gz 内二进制可能在不同目录结构下，搜索查找
                find "${_tmpdir_}" -type f -name "${_bin_}" -exec cp -f {} "${_dest_}/${_bin_}" \; 2>/dev/null || true
                # tailscale 等同时提供两个二进制
                find "${_tmpdir_}" -type f -name "${_bin_}d" -exec cp -f {} "${_dest_}/${_bin_}d" \; 2>/dev/null || true
            fi
            ;;
        *)
            cp -f "${_tmpdir_}/${_asset_}" "${_dest_}/${_bin_}"
            ;;
    esac

    chmod +x "${_dest_}/${_bin_}"
    [ -f "${_dest_}/${_bin_}d" ] && chmod +x "${_dest_}/${_bin_}d" 2>/dev/null || true
    rm -rf "${_tmpdir_}"
    echo "[dl] ${_bin_} 安装完成 (${_dest_}/${_bin_})"
}

# ============================================================
#  GitHub API —— 获取最新 release tag
# ============================================================
# _gh_latest_tag <owner/repo>
#   输出该仓库最新 release 的 tag_name（如 v1.10.0）
_gh_latest_tag() {
    _repo_="$1"
    curl -fsSL "https://api.github.com/repos/${_repo_}/releases/latest" | \
        grep '"tag_name"' | head -1 | \
        sed 's/.*"tag_name": *"\(.*\)".*/\1/'
}
