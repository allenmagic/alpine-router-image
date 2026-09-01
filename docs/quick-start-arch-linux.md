# 在 Arch Linux 上快速启动 Alpine Router MicroVM

本指南演示如何在非 NixOS 系统（如 Arch Linux）上快速测试 router VM。

## 方案选择

### 推荐：使用 smoke-test.sh（最简单）

`test/smoke-test.sh` 已实现完整的下载、校验、启动流程，**无需任何前置配置**：

```bash
cd /path/to/microvm-router-image

# 使用 qemu 启动 Alpine rootfs + 官方内核
bash test/smoke-test.sh alpine

# 使用 cloud-hypervisor（需要 /dev/kvm 可读写）
bash test/smoke-test.sh alpine --backend cloud-hypervisor

# 使用自建精简内核（4.0M vs 12M）
bash test/smoke-test.sh alpine --kernel custom

# 启用日志断言（检查启动日志中的错误）
bash test/smoke-test.sh alpine --kernel custom --assert
```

**优点**：
- ✅ 无需预先创建网络桥接
- ✅ 自动下载并校验 sha256
- ✅ 支持 qemu 和 cloud-hypervisor
- ✅ 支持两种内核变体（alpine / custom）
- ✅ 串口直接输出到终端，`Ctrl+C` 停止

**限制**：
- 网络使用 user-mode（guest 可以访问外网，但宿主无法直接 ssh 进 guest）
- 需要手动停止（`Ctrl+C`）

### 方案 B：NixOS 宿主 + declarative 配置（生产环境）

完整功能需要 NixOS 宿主，参见 `README.md` 的"消费端集成"章节：

```nix
# configuration.nix
{
  inputs.microvm-router-image.url = "github:allenmagic/microvm-router-image";

  imports = [ inputs.microvm-router-image.nixosModules.router ];

  microvm.router = {
    enable = true;
    os = "alpine";
    kernel = "alpine";

    cpu = 0;              # 独占核（需要宿主 isolcpus 内核参数）
    vcpus = 2;
    mem = 512;
    initialBalloonMem = 256;

    wanBridge = "br-wan"; # 需要在宿主上预先配置
    lanBridge = "br-lan";
    vmIp = "192.168.10.1";
  };
}
```

**优点**：
- ✅ Declarative 配置，可版本管理
- ✅ systemd 自动启动（`microvm@alpine-router.service`）
- ✅ 完整网络桥接，宿主可以 ssh 进 guest
- ✅ CPU 独占（isolcpus）、动态内存（balloon）
- ✅ 自动化密钥注入（`alpine-router-deploy` 命令）

**要求**：
- 必须是 NixOS 宿主
- 需要手动配置网络桥接（或用 systemd-networkd declarative 配置）

## 前置条件（smoke-test.sh）

1. **KVM 支持**
   ```bash
   # 确认 /dev/kvm 可读写
   ls -l /dev/kvm
   # 当前用户需要在 kvm 组内
   sudo usermod -aG kvm $USER
   # 重新登录生效
   ```

2. **依赖工具**
   ```bash
   # Arch Linux
   sudo pacman -S qemu-system-x86 cloud-hypervisor curl

   # 或只用 qemu（无需 cloud-hypervisor）
   sudo pacman -S qemu-system-x86 curl
   ```

## 详细用法

查看完整选项：
```bash
bash test/smoke-test.sh --help
```

常用场景：

```bash
# 测试 gentoo rootfs（需等 CI 完成 gentoo 构建）
bash test/smoke-test.sh gentoo

# 指定 release tag
bash test/smoke-test.sh alpine --tag microvm-router-vm-20260901

# 只下载不启动
bash test/smoke-test.sh alpine --verify-only

# 通过代理下载
bash test/smoke-test.sh alpine --proxy

# 自定义内核日志级别（3 = 只显示严重错误）
bash test/smoke-test.sh alpine --loglevel 3

# 自建内核 + 不传 initramfs（测试全 builtin 引导）
bash test/smoke-test.sh alpine --kernel custom --no-initrd
```

## VM 内操作

VM 启动后会显示串口输出，登录信息：
- 用户：`root`
- 密码：`root`

可以执行的测试：
```bash
# 查看内核版本
uname -a

# 查看网络
ip addr

# 查看 nftables 规则（路由器配置）
nft list ruleset

# 测试外网连通性
ping 8.8.8.8

# 查看模块加载情况
lsmod
```

退出：`Ctrl+C`

## 常见问题

### 1. `Permission denied: /dev/kvm`
```bash
sudo usermod -aG kvm $USER
# 重新登录生效
```

### 2. `cloud-hypervisor: command not found`
使用 qemu 后端（默认）：
```bash
bash test/smoke-test.sh alpine  # 不加 --backend 选项
```

或安装 cloud-hypervisor：
```bash
# Arch Linux AUR
yay -S cloud-hypervisor
```

### 3. 如何修改内核变体？
```bash
# 官方内核（稳定，Alpine 安全回补）
bash test/smoke-test.sh alpine --kernel alpine

# 自建内核（精简，4.0M vs 12M）
bash test/smoke-test.sh alpine --kernel custom
```

### 4. 如何访问 guest 网络？
`smoke-test.sh` 使用 user-mode networking（SLIRP）：
- ✅ Guest 可以访问外网（通过宿主 NAT）
- ❌ 宿主无法直接 ssh 进 guest

如需完整桥接，使用 NixOS 宿主方案。

### 5. 下载速度慢？
```bash
# 使用代理（需预先安装 proxychains）
bash test/smoke-test.sh alpine --proxy

# 或手动下载后使用本地缓存
mkdir -p build/smoke-assets
cd build/smoke-assets
curl -LO https://github.com/allenmagic/microvm-router-image/releases/download/microvm-router-vm-20260901/alpine-rootfs.qcow2
# ... 下载其他资产
cd ../..
bash test/smoke-test.sh alpine --no-download
```

## 下一步

- **生产部署**：参见 `README.md` 的"消费端集成"章节（需要 NixOS 宿主）
- **自定义镜像**：参见 `image/README.md` 构建自己的 rootfs
- **自建内核**：参见 `kernel/README.md` 调整内核配置

## 限制说明

`smoke-test.sh` 是**测试工具**，适合快速验证镜像功能，不适合生产环境：
- ❌ 无自动启动（需手动运行脚本）
- ❌ 无网络桥接（user-mode networking）
- ❌ 无状态持久化（VM 退出后数据丢失）
- ❌ 无密钥注入（使用默认 root/root 密码）

完整功能需要 NixOS 宿主 + declarative 配置。
