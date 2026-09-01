# 独立的 MicroVM Guest 配置（用于 nix run 快速测试）
#
# 这个配置直接定义一个 microVM guest，可以在任何安装了 Nix 的系统上运行。
# 与 router.nix 的区别：
# - router.nix 是宿主侧模块，用 microvm.vms.* 管理 VM（需要 NixOS）
# - 本配置是 guest 侧模块，直接定义 VM 内部（可在 Arch Linux 等非 NixOS 上运行）
#
# 用法:
#   nix run .#test-guest-qemu
#
# 前置条件（Arch Linux）:
#   - Nix 已安装（你已有）
#   - qemu-system-x86_64：sudo pacman -S qemu-system-x86
#   - /dev/kvm 可读写：sudo usermod -aG kvm $USER（重新登录）
{ config, pkgs, lib, ... }:

let
  # 使用本仓库的 release 资产（与 router.nix 同源）
  imageRelease = "microvm-router-vm-20260901";
  releaseBase = "https://github.com/allenmagic/microvm-router-image/releases/download/${imageRelease}";

  # 预先下载镜像到 /nix/store
  rootfsImage = pkgs.fetchurl {
    url = "${releaseBase}/alpine-rootfs.qcow2";
    sha256 = "c76bb0cb6fa3dd79c8460a97aa9bda3a7b7f3ce5e7e21c2cdc9c4889c6b43906";
  };
in {
  # microVM 基础配置
  microvm = {
    # qemu 后端（cloud-hypervisor 需要内核有 .dev 输出，我们只有 bzImage）
    hypervisor = "qemu";

    vcpu = 2;
    mem = 512;

    # 网络：使用 user-mode networking（不需要 root 和桥接）
    # 限制：guest 可以访问外网，但宿主无法直接访问 guest
    interfaces = [
      {
        type = "user";
        id = "user";
        mac = "02:00:00:01:01:01";
      }
    ];

    # 从本仓库 release 拉取内核和 initrd
    kernel = pkgs.fetchurl {
      url = "${releaseBase}/vmlinuz-virt";
      sha256 = "1e6bf9027720c75c3ed0d79171f21b5791ee40ca9795d07c7c6e04dc5ea2ae90";
    };

    initrdPath = pkgs.fetchurl {
      url = "${releaseBase}/initrd";
      sha256 = "f407d5023c2a94ad449f199d9776b7e586d50627ae6ca90aafb1ef48dcfc11ef";
    };

    # 根磁盘：microvm.nix 需要在构建时知道镜像路径，但又不能直接用字符串插值
    # 解决方案：使用 preStart 脚本在运行时复制镜像
    volumes = [{
      image = "/tmp/microvm-test-root.qcow2";  # 运行时路径
      mountPoint = "/";
      autoCreate = false;
    }];

    # 内核参数
    kernelParams = [ "root=/dev/vda" "rootfstype=ext4" "rw" "console=ttyS0" ];

    # 共享宿主的 /nix/store（可选，性能优化）
    shares = [{
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }];

    # 可写 store overlay
    writableStoreOverlay = "/nix/.rw-store";
  };

  # 启动前复制镜像（从 /nix/store 的只读副本到可写临时文件）
  systemd.services.microvm-prep = {
    description = "Prepare MicroVM root disk";
    wantedBy = [ "multi-user.target" ];
    script = ''
      if [ ! -f /tmp/microvm-test-root.qcow2 ]; then
        echo "Copying root disk from ${rootfsImage}..."
        cp ${rootfsImage} /tmp/microvm-test-root.qcow2
        chmod 644 /tmp/microvm-test-root.qcow2
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # 系统配置
  system.stateVersion = "26.05";
  networking.hostName = "alpine-router-test";

  # 禁用不必要的服务（减少评估开销）
  documentation.enable = false;
  documentation.nixos.enable = false;
}
