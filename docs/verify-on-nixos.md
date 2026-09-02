# 在 NixOS 上验证 router.nix 模块

本指南介绍如何验证 `router.nix` 模块在 NixOS 宿主上的完整功能。

## 方案对比

| 方案 | 适用场景 | 复杂度 | 验证完整度 |
|---|---|---|---|
| **方案 1：NixOS VM** | 在 Arch Linux 等非 NixOS 上测试 | 中等 | 高（嵌套虚拟化） |
| **方案 2：GitHub Actions CI** | 自动化测试 | 低 | 中（无 KVM） |
| **方案 3：真实 NixOS** | 有 NixOS 机器 | 低 | 最高 |

## 方案 1：使用 NixOS VM（推荐）

在非 NixOS 系统（如 Arch Linux）上构建一个 NixOS VM，在其中运行 router VM（嵌套虚拟化）。

### 前置条件

- Nix 已安装
- /dev/kvm 可读写（嵌套虚拟化需要）
- 至少 8GB 内存（宿主 VM 4GB + router VM 512MB）

### 构建并启动

```bash
cd /path/to/router-image

# 构建 NixOS VM（首次需要下载 NixOS 依赖，~3-5GB）
nix build .#nixosConfigurations.test-nixos-host.config.system.build.vm

# 启动 VM
./result/bin/run-nixos-test-host-vm
```

**说明**：
- 这会启动一个完整的 NixOS 系统（宿主）
- NixOS 宿主会自动启动 `alpine-router` microVM（通过 systemd）
- 两层虚拟化：外层是 qemu VM（NixOS 宿主），内层是 cloud-hypervisor VM（alpine-router）

### 验证步骤

VM 启动后，在宿主 VM 的终端里：

```bash
# 1. 检查 microvm 服务状态
systemctl status microvm@alpine-router.service

# 2. 检查网络桥接
ip link show br-wan
ip link show br-lan
ip link show router-wan
ip link show router-lan

# 3. SSH 进入 router VM
ssh root@192.168.10.1
# 密码：root

# 4. 在 router VM 内验证
uname -a                    # 查看内核版本
ip addr                     # 查看网络配置
nft list ruleset            # 查看 nftables 规则
ping 8.8.8.8                # 测试外网连通性

# 5. 退出 router VM
exit

# 6. 测试部署工具（可选）
alpine-router-deploy
```

### 清理

```bash
# 删除 VM 镜像（位于 ~/.cache/nixos-vm/）
rm -rf ~/.cache/nixos-vm/
```

### 限制

- **嵌套虚拟化性能**：外层 qemu + 内层 cloud-hypervisor，性能比真实 NixOS 差
- **CPU 隔离无效**：`isolcpus` 在 VM 内不生效（需要宿主内核参数）
- **网络拓扑简化**：测试桥接是虚拟的，没有连接真实物理接口

## 方案 2：GitHub Actions CI

在 CI 中验证配置解析和服务定义的正确性（无法实际启动 VM，因为 GitHub Actions 不支持 KVM）。

### 添加 CI workflow

```yaml
# .github/workflows/test-router-module.yml
name: Test router.nix module

on: [push, pull_request]

jobs:
  test-module:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - uses: cachix/install-nix-action@v27
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes
      
      - name: Check flake
        run: nix flake check
      
      - name: Evaluate test-nixos-host config
        run: |
          nix eval .#nixosConfigurations.test-nixos-host.config.system.name
          nix eval .#nixosConfigurations.test-nixos-host.config.microvm.router.enable
      
      - name: Build (dry-run)
        run: |
          nix build --dry-run .#nixosConfigurations.test-nixos-host.config.system.build.toplevel
```

**验证范围**：
- ✅ 配置语法正确
- ✅ 模块选项定义正确
- ✅ 依赖关系正确
- ❌ 无法实际启动 VM（无 /dev/kvm）

## 方案 3：真实 NixOS 宿主

如果你有一台 NixOS 机器（物理机或 VPS），可以直接测试完整功能。

### 配置示例

```nix
# /etc/nixos/configuration.nix
{ config, pkgs, ... }:

{
  imports = [
    # 从本地 checkout 导入（开发测试）
    /path/to/router-image/nixos-modules/router.nix
    
    # 或从 GitHub 导入（生产环境）
    # (builtins.fetchGit {
    #   url = "https://github.com/allenmagic/router-image";
    #   ref = "main";
    # } + "/nixos-modules/router.nix")
  ];

  microvm.router = {
    enable = true;
    os = "alpine";
    kernel = "alpine";

    cpu = 0;              # 根据你的硬件调整
    vcpus = 2;
    mem = 512;
    initialBalloonMem = 256;

    # 使用真实的网络接口
    wanBridge = "br-wan";  # 连接到上游路由器/ISP
    lanBridge = "br-lan";  # 连接到下游设备
    vmIp = "192.168.10.1";
  };

  # 配置真实的网络桥接
  systemd.network = {
    enable = true;
    netdevs = {
      "10-br-wan".netdevConfig = {
        Kind = "bridge";
        Name = "br-wan";
      };
      "10-br-lan".netdevConfig = {
        Kind = "bridge";
        Name = "br-lan";
      };
    };
    networks = {
      # 将物理接口加入桥
      "20-wan".networkConfig.Bridge = "br-wan";
      "20-wan".matchConfig.Name = "enp1s0";  # 你的上游接口
      
      "20-lan".networkConfig.Bridge = "br-lan";
      "20-lan".matchConfig.Name = "enp2s0";  # 你的下游接口
    };
  };

  # CPU 隔离（可选，生产推荐）
  boot.kernelParams = [ "isolcpus=0" "rcu_nocbs=0" ];
}
```

### 应用配置

```bash
# 切换到新配置
sudo nixos-rebuild switch

# 检查服务状态
systemctl status microvm@alpine-router.service

# 查看日志
journalctl -u microvm@alpine-router.service -f

# SSH 进入 router VM
ssh root@192.168.10.1

# 部署密钥（可选）
sudo cp /etc/libvirt/alpine-router.env.example /etc/libvirt/alpine-router.env
sudo vim /etc/libvirt/alpine-router.env  # 填入真实密钥
sudo chmod 600 /etc/libvirt/alpine-router.env
alpine-router-deploy
```

### 验证完整功能

```bash
# 1. 检查 VM 是否运行
systemctl status microvm@alpine-router.service

# 2. 检查网络
ping 192.168.10.1
ssh root@192.168.10.1 'ip addr'

# 3. 检查 CPU 隔离
taskset -cp $(pgrep cloud-hypervisor)  # 应该只显示 CPU 0

# 4. 检查动态内存（balloon）
ssh root@192.168.10.1 'free -h'

# 5. 下游设备连通性测试
# 将一台设备连接到 br-lan，配置 IP 192.168.10.x/24
# 测试能否通过 router VM 访问外网
```

## 推荐验证流程

1. **开发阶段**：使用 **方案 1（NixOS VM）** 在 Arch Linux 上快速迭代
2. **集成测试**：添加 **方案 2（GitHub Actions）** 确保每次提交配置正确
3. **生产部署前**：在 **方案 3（真实 NixOS）** 上做最终验证

## 常见问题

### Q1: NixOS VM 构建失败
```bash
# 检查 Nix 配置
nix doctor

# 清理缓存重试
nix-collect-garbage -d
nix build .#nixosConfigurations.test-nixos-host.config.system.build.vm
```

### Q2: 嵌套虚拟化不工作
检查 CPU 是否支持嵌套虚拟化：
```bash
# Intel
cat /sys/module/kvm_intel/parameters/nested  # 应该是 Y

# AMD
cat /sys/module/kvm_amd/parameters/nested    # 应该是 1

# 如果不支持，需要启用（重启后生效）
echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
```

### Q3: microvm 服务启动失败
```bash
# 查看详细日志
journalctl -u microvm@alpine-router.service -n 50

# 常见原因：
# - 桥接未创建：检查 systemd.network 配置
# - 镜像未准备：检查 alpine-router-disk.service 日志
# - KVM 权限：检查 /dev/kvm 可读写
```

### Q4: 如何回滚到 smoke-test.sh？
如果 NixOS VM 方案太复杂，回退到简单测试：
```bash
# smoke-test.sh 仍然是最快的验证方式
bash test/smoke-test.sh alpine --kernel custom --assert
```

## 下一步

- 完整的生产部署指南：参见 `README.md`
- 自定义镜像构建：参见 `image/README.md`
- 自建内核配置：参见 `kernel/README.md`
