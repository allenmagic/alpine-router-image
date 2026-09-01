# 测试配置：在 Arch Linux 宿主上直接启动 Alpine Router MicroVM
#
# 用法:
#   nix run .#nixosConfigurations.test-router.config.microvm.vms.alpine-router.runner.cloud-hypervisor
#
# 这是一个最小化的宿主配置，演示如何使用 router.nix 模块在非 NixOS 系统上
# 启动 router VM。生产环境应基于 NixOS 宿主，参见 qnap-nixos-nas 的实际用法。
{ config, pkgs, lib, ... }:

{
  # 启用 router 模块
  microvm.router = {
    enable = true;
    os = "alpine";       # rootfs 发行版：alpine | gentoo
    kernel = "alpine";   # 内核变体：alpine（官方稳定） | custom（自建精简）

    # 硬件资源
    cpu = 0;             # 隔离核号（非 NixOS 宿主上 isolcpus 不生效，只设 affinity）
    vcpus = 2;
    mem = 512;
    initialBalloonMem = 256;

    # 网络桥接（需要预先在 Arch 上创建 br-wan / br-lan）
    # 如果没有桥接，VM 启动会失败。快速测试可以先创建空桥：
    #   sudo ip link add br-wan type bridge
    #   sudo ip link add br-lan type bridge
    #   sudo ip link set br-wan up
    #   sudo ip link set br-lan up
    wanBridge = "br-wan";
    lanBridge = "br-lan";
    vmIp = "192.168.10.1";
  };

  # 系统基础配置（microvm.nix 要求）
  system.stateVersion = "26.05";
  networking.hostName = "test-host";

  # 关闭 NixOS 宿主特有的服务（在非 NixOS 上无意义）
  boot.isContainer = true;  # 禁用引导加载器等硬件配置
  services.getty.autologinUser = lib.mkForce null;
}
