# 独立的 MicroVM Guest 配置（用于 nix run 快速测试）
#
# 这个配置直接定义一个 microVM guest，不需要 NixOS 宿主。
# 与 router.nix 的区别：
# - router.nix 是宿主侧模块，用 microvm.vms.* 管理 VM（需要 NixOS）
# - 本配置是 guest 侧模块，直接定义 VM 内部（可以在任何有 Nix 的系统上 nix run）
#
# 用法:
#   nix run .#test-guest-cloud-hypervisor
#   nix run .#test-guest-qemu
{ config, pkgs, lib, ... }:

let
  # 使用本仓库的 release 资产（与 router.nix 同源）
  imageRelease = "microvm-router-vm-20260901";
  releaseBase = "https://github.com/allenmagic/microvm-router-image/releases/download/${imageRelease}";
in {
  # microVM 基础配置
  microvm = {
    # cloud-hypervisor 需要内核包有 .dev 输出（vmlinux ELF），
    # 但我们的 release 只有 bzImage。先用 qemu 测试。
    hypervisor = "qemu";

    vcpu = 2;
    mem = 512;

    # 动态内存（qemu 不支持 balloon，注释掉）
    # balloon = true;
    # initialBalloonMem = 256;
    # deflateOnOOM = true;

    # 网络：使用 user-mode networking（不需要 root 和桥接）
    # 限制：guest 可以访问外网，但宿主无法直接访问 guest
    interfaces = [
      {
        type = "user";
        id = "user";
        mac = "02:00:00:01:01:01";
      }
    ];

    # 从本仓库 release 拉取镜像
    kernel = pkgs.fetchurl {
      url = "${releaseBase}/vmlinuz-virt";
      sha256 = "1e6bf9027720c75c3ed0d79171f21b5791ee40ca9795d07c7c6e04dc5ea2ae90";
    };

    initrdPath = pkgs.fetchurl {
      url = "${releaseBase}/initrd";
      sha256 = "f407d5023c2a94ad449f199d9776b7e586d50627ae6ca90aafb1ef48dcfc11ef";
    };

    volumes = [{
      image = "${pkgs.fetchurl {
        url = "${releaseBase}/alpine-rootfs.qcow2";
        sha256 = "c76bb0cb6fa3dd79c8460a97aa9bda3a7b7f3ce5e7e21c2cdc9c4889c6b43906";
      }}";
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

  # 系统配置
  system.stateVersion = "26.05";
  networking.hostName = "alpine-router-test";

  # 禁用不必要的服务
  documentation.enable = false;
  documentation.nixos.enable = false;
}