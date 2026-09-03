# 从 microvm.router 迁移到 services.router-vm

> 目标消费端：qnap-nixos-nas（唯一消费端）。重构决策与背景见
> `docs/refactor-proposal.md`。

## 变更总览

| 维度 | 旧（microvm.router） | 新（services.router-vm） |
|---|---|---|
| flake 输入 | `microvm-router-image`（现已改名 router-image）+ microvm.nix | 仅 `router-image` |
| 命名空间 | `microvm.router.*` | `services.router-vm.*` |
| 内核/initrd 选项 | `kernel` / `kernelFile` / `initrd`（双变体） | 无（唯一自建内核） |
| 状态 | rootfs 可写副本（升级=状态清零） | guest 无状态 + 宿主 sops-nix 密钥 |
| 密钥注入 | 手工 `alpine-router-deploy`（env 文件） | 自动 `router-vm-deploy.service`（/run/secrets） |
| 服务单元 | `microvm@alpine-router.service` | `router-vm.service` + `router-vm-deploy.service` |

## 迁移步骤

### 1. flake.nix

```diff
   inputs = {
-    microvm-router-image.url = "github:allenmagic/microvm-router-image";
-    microvm.url = "github:astro/microvm.nix";
+    router-image.url = "github:allenmagic/router-image";
     nixpkgs.url = "...";
     ...
   };
```

### 2. 宿主模块

```diff
   imports = [
-    microvm.nixosModules.host
-    inputs.microvm-router-image.nixosModules.router
+    inputs.router-image.nixosModules.router
   ];
```

### 3. VM 声明

```diff
-  microvm.router = {
+  services.router-vm = {
     enable = true;
     os = "alpine";
-    kernel = "alpine";      # 选项删除：内核唯一（自建 vmlinuz-router）
     cpu = 0;
     vcpus = 2;
     mem = 512;
     initialBalloonMem = 256;
     wanBridge = "br-wan";
     lanBridge = "br-lan";
     vmIp = "192.168.10.1";
+    secretsDir = "/run/secrets";   # 默认值，可省略
   };
```

桥接与网口配置（systemd.network）**无需改动**——tap 名称（router-wan /
router-lan）与 MAC 沿用，networkd 的挂桥规则由模块生成。

### 4. 密钥：env 文件 → sops-nix

旧流程的 `/etc/libvirt/alpine-router.env` 废弃，密钥改为 sops 加密进 git：

```nix
# 宿主 flake：引入 sops-nix（如已有则跳过）
#   inputs.sops-nix.url = "github:Mic92/sops-nix";
#   inputs.sops-nix.inputs.nixpkgs.follows = "nixpkgs";
# 宿主模块：
#   imports = [ inputs.sops-nix.nixosModules.sops ];

sops.secrets."ssh-public-key" = { sopsFile = ./secrets.yaml; };
sops.secrets."tailscale-auth-key" = { sopsFile = ./secrets.yaml; };
sops.secrets."cloudflared-token" = { sopsFile = ./secrets.yaml; };
```

```yaml
# secrets.yaml（sops 加密后进 git）
ssh-public-key: |
  ssh-ed25519 AAAA... deploy-key
tailscale-auth-key: tskey-auth-xxxxxxxxxxxxxxxx
cloudflared-token: eyJhIjoi...
```

激活后 sops 解密到 `/run/secrets/`，`router-vm-deploy.service` 在每次
VM 启动后自动注入 guest（PartOf router-vm.service，重启 VM 自动重跑）。
原手工 `alpine-router-deploy` 命令更名为 `router-vm-deploy`（一般不再需要）。

### 5. Tailscale 登录

登录从 deploy 内自动 `tailscale up` 改为**手动触发**（authkey 经 config.json
的 `file:` 机制被 tailscaled 读取）：

```bash
ssh root@192.168.10.1 'tailscale up'
```

每次 VM 重启 = 新节点身份（hostname 固定，管理台可辨；旧节点过期消失）。
若节点 churn 不可接受，方案预留了「tailscaled.state 单独小状态盘」升级路径
（见 refactor-proposal §5 风险表）。

## 迁移后验证

```bash
nixos-rebuild switch
systemctl status router-vm            # VM 运行
systemctl status router-vm-deploy     # 密钥注入成功
ssh root@192.168.10.1 'cat /root/.ssh/authorized_keys'   # 已注入
ssh root@192.168.10.1 'tailscale up'  # 登录 tailscale
```

完整验收清单见 `docs/verify-on-nixos.md`（方案 3）。

## 回滚

- 旧 release tag（`microvm-router-vm-*`）资产不可变，仍可下载
- 本仓库旧模块已删除；回滚到旧方案需 checkout 重构前的 commit
  （`git revert` 消费端变更后 `flake.lock` 退回旧 input）
- GitHub 仓库改名有 301 重定向，旧 flake URL 仍可用
