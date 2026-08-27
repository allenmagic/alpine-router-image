#!/bin/sh
#
# lib/secrets.sh —— 密钥注入（Tailscale / Cloudflared）
#   被 install.sh source 调用
#   定义 inject_secrets() 和 tailscale_up()
#
#   密钥来自环境变量（由 env 文件加载，见 env.example），
#   绝不写入部署包或日志。
#

inject_secrets() {
    echo "[secrets] === 密钥注入 ==="

    # SSH 公钥：写入 /root/.ssh/authorized_keys（deploy 通道本身与日常登录；
    # r3s 出厂 sshd 默认拒绝 root 密码登录，公钥是唯一免密通道）
    # 支持多个 key：SSH_PUBLIC_KEY 每行一个公钥（如部署机 + 个人设备各一行），
    # 覆盖写保持 deploy 幂等（authorized_keys 以 env 文件为准）
    if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        printf '%s\n' "${SSH_PUBLIC_KEY}" > /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        echo "  → SSH 公钥已注入"
    else
        echo "  → 未提供 SSH_PUBLIC_KEY，跳过"
    fi

    # Tailscale: authkey 写入 /etc/tailscale/authkey（config.json 引用）
    if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
        mkdir -p /etc/tailscale
        printf '%s' "${TAILSCALE_AUTH_KEY}" > /etc/tailscale/authkey
        chmod 600 /etc/tailscale/authkey
        echo "  → Tailscale authkey 已注入"
    else
        echo "  → 未提供 TAILSCALE_AUTH_KEY，跳过"
    fi

    # Cloudflared: token 写入 /etc/cloudflared/config.yml 后重启服务——
    # 出厂时服务已在跑（无 token 空转），注入 token 必须重启才生效
    if [ -n "${CLOUDFLARED_TOKEN:-}" ]; then
        mkdir -p /etc/cloudflared
        printf 'token: %s\n' "${CLOUDFLARED_TOKEN}" > /etc/cloudflared/config.yml
        chmod 600 /etc/cloudflared/config.yml
        rc-service cloudflared restart 2>/dev/null || true
        echo "  → Cloudflared token 已注入并重启服务"
    else
        echo "  → 未提供 CLOUDFLARED_TOKEN，跳过"
    fi
}

tailscale_up() {
    if [ -f /etc/tailscale/authkey ]; then
        # 无 authkey 启动时 tailscaled 可能已退出（crashed），
        # 先确保服务在跑（rc-service start 幂等）再登录
        echo "[secrets] 确保 tailscaled 运行..."
        rc-service tailscale start 2>/dev/null || true
        sleep 1
        echo "[secrets] Tailscale 登录（authkey）..."
        tailscale up
    else
        echo "[secrets] 未提供 authkey，跳过 Tailscale 登录（可稍后手动 tailscale up）"
    fi
}
