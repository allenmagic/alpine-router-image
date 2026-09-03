# Router VM 部署目录

本目录是 Router VM 的**密钥注入器**（deploy 资产）。

**职责边界**：VM 的全部配置（nftables/dnsmasq/sysctl/服务脚本/网络参数）已由
[router-image](https://github.com/allenmagic/router-image) 仓库的 CI
烙进镜像（出厂即正确），本目录只承载密钥类数据，deploy 时注入。

## 目录结构

```
deploy-assets/
├── lib/
│   └── secrets.sh                # 密钥注入（SSH 公钥 / Tailscale / Cloudflared）
├── install.sh                    # 注入脚本（VM 内 root 执行，结束后清理 env）
├── env.example                   # 部署密钥模板（手工部署用）
└── README.md
```

## 密钥注入（sops-nix，自动）

生产流程密钥由宿主 sops-nix 管理：加密进 git，激活时解密到
`/run/secrets`，`router-vm-deploy`（systemd 服务）在**每次 VM 启动后**
自动 scp 注入 guest 的 `/run`（tmpfs）：

```bash
# 宿主侧：无需任何手工操作，VM 重启后密钥自动恢复
systemctl status router-vm-deploy
```

注入路径（guest 无状态，以下均为构建期烙入的符号链接 → `/run`）：

- `SSH_PUBLIC_KEY` → `/root/.ssh/authorized_keys`（deploy 通道本身与日常登录；
  **支持多个 key**：每行一个公钥，如部署机 key + 个人设备 key）
- `TAILSCALE_AUTH_KEY` → `/etc/tailscale/authkey`（config.json 通过
  `authKey: file:` 引用；注入后自动启动 tailscaled 并后台 `tailscale up`
  登录，key 须为「可复用 reusable」类型）
- `CLOUDFLARED_TOKEN` → `/etc/cloudflared/config.yml`（注入后自动重启服务）

install.sh 结束（含失败）时删除 env 文件。不提供密钥则跳过对应功能。
sops 密钥文件约定：`<secretsDir>/ssh-public-key`、
`<secretsDir>/tailscale-auth-key`、`<secretsDir>/cloudflared-token`
（默认目录 `/run/secrets`，见模块的 `secretsDir` option）。

## 手工部署（调试/迁移场景）

```bash
# 宿主侧：传统 env 文件方式（sops 未接时）
sudo cp /etc/router-vm/env.example /tmp/router-vm.env
sudo chmod 600 /tmp/router-vm.env
sudo vim /tmp/router-vm.env      # 填入密钥
sudo ROUTER_VM_ENV_FILE=/tmp/router-vm.env router-vm-deploy
```

## 更新配置

**改配置**：改 [router-image](https://github.com/allenmagic/router-image)
的 `base/` 或 `network.env` → 触发其 CI → CI 自动把 release 的 tag + sha256 同步进
`nixos-modules/router.nix`（`sync-flake-sha.py`，无需手工）→ 宿主侧
`nix flake update` → `nixos-rebuild switch` → VM 自动重启（rootfs 只读副本
哈希路径变化）→ router-vm-deploy 自动重新注入密钥。

**改密钥**：编辑宿主 sops 的 `secrets.yaml` → `nixos-rebuild switch`
（sops 重新解密到 /run/secrets）→ 手动 `systemctl restart router-vm-deploy`
（或重启 VM，deploy 服务随 VM 自动重跑）。

## 部署前检查清单

| 项 | 位置 | 说明 |
|---|---|---|
| `ssh-public-key` | 宿主 sops secrets.yaml | `ssh-keygen -t ed25519` 生成后填入 |
| `tailscale-auth-key` | 同上 | Tailscale 管理后台生成可复用（reusable）key |
| `cloudflared-token` | 同上 | Cloudflare Zero Trust 隧道页获取 |

镜像 tag 与资产 sha256 无需手工替换——由 CI 的 `sync-flake-sha.py` 自动同步。
