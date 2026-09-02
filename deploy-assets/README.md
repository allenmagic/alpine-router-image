# Microvm Router 部署目录

本目录是 Microvm Router VM 的**密钥注入器**（deploy 资产）。

**职责边界**：VM 的全部配置（nftables/dnsmasq/sysctl/服务脚本/网络参数）已由
[router-image](https://github.com/allenmagic/router-image) 仓库的 CI
烙进镜像（出厂即正确），本目录只承载密钥类数据，deploy 时注入。

## 目录结构

```
alpine-router/
├── lib/
│   └── secrets.sh                # 密钥注入（SSH 公钥 / Tailscale / Cloudflared）
├── install.sh                    # 注入脚本（VM 内 root 执行，结束后清理 env）
├── env.example                   # 部署密钥模板
└── README.md
```

## 密钥注入（env 文件）

密钥通过 env 文件注入，**不写入部署包**：

```bash
# 在 NAS 宿主机上
sudo cp env.example /etc/libvirt/alpine-router.env
sudo chmod 600 /etc/libvirt/alpine-router.env
# 编辑填入密钥：
#   SSH_PUBLIC_KEY="ssh-ed25519 AAAA..."（deploy 通道与日常登录）
#   TAILSCALE_AUTH_KEY=tskey-auth-...
#   CLOUDFLARED_TOKEN=eyJhIjoi...
```

`alpine-router-deploy` 把该文件 scp 到 VM 并重命名为 `./env`，install.sh source 后：

- `SSH_PUBLIC_KEY` → `/root/.ssh/authorized_keys`（镜像出厂 sshd 默认拒绝 root 密码登录，公钥是唯一免密通道；**支持多个 key**：每行一个公钥，如部署机 key + 个人设备 key）
- `TAILSCALE_AUTH_KEY` → `/etc/tailscale/authkey`（config.json 通过 `authKey: file:` 引用），随后自动 `tailscale up`
- `CLOUDFLARED_TOKEN` → `/etc/cloudflared/config.yml`

install.sh 结束（含失败）时删除 env 文件。不提供密钥则跳过对应功能。

## 更新配置

**改配置**：改 [router-image](https://github.com/allenmagic/router-image)
的 `base/` 或 `network.env` → 触发其 CI → CI 自动把 release 的 tag + sha256 同步进
`nixos-modules/router.nix`（`sync-flake-sha.py`，无需手工）→ NAS 侧
`nix flake update` → `nixos-rebuild switch` → 重启 VM（disk-prep 自动重装状态盘）→
`alpine-router-deploy` 注入密钥。

**改密钥**：编辑 `/etc/libvirt/alpine-router.env` → `alpine-router-deploy`。

## 部署前检查清单（占位项）

| 占位项 | 位置 | 替换方式 |
|---|---|---|
| `SSH_PUBLIC_KEY` | `/etc/libvirt/alpine-router.env` | `ssh-keygen -t ed25519 -f /etc/libvirt/alpine-router-deploy` 后填 `.pub` 内容 |
| `TAILSCALE_AUTH_KEY` | 同上 | Tailscale 管理后台生成一次性 key |
| `CLOUDFLARED_TOKEN` | 同上 | Cloudflare Zero Trust 隧道页获取 |

镜像 tag 与三处 sha256 无需手工替换——由 CI 的 `sync-flake-sha.py` 自动同步。
