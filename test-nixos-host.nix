# NixOS 宿主测试配置
#
# 用途：在非 NixOS 系统上构建一个 NixOS VM 来验证 router.nix 模块的完整功能
#
# 用法:
#   nix build .#nixosConfigurations.test-nixos-host.config.system.build.vm
#   ./result/bin/run-*-vm
#
# 这会启动一个完整的 NixOS VM（宿主），其中运行着 alpine-router（嵌套 VM）。
{ config, pkgs, lib, ... }:

{
  imports = [
    # 导入 router 模块
    ./nixos-modules/router.nix
  ];

  # 基础 NixOS 配置
  system.stateVersion = "26.05";
  networking.hostName = "nixos-test-host";

  # 启用 router VM
  microvm.router = {
    enable = true;
    os = "alpine";
    kernel = "alpine";

    cpu = 0;
    vcpus = 2;
    mem = 512;
    initialBalloonMem = 256;

    # 测试环境：创建虚拟桥接
    wanBridge = "br-wan";
    lanBridge = "br-lan";
    vmIp = "192.168.10.1";
  };

  # 创建测试用的网络桥接
  systemd.network = {
    enable = true;
    netdevs = {
      "10-br-wan" = {
        netdevConfig = {
          Kind = "bridge";
          Name = "br-wan";
        };
      };
      "10-br-lan" = {
        netdevConfig = {
          Kind = "bridge";
          Name = "br-lan";
        };
      };
    };
    networks = {
      "10-br-wan" = {
        matchConfig.Name = "br-wan";
        networkConfig = {
          Address = "192.168.1.1/24";
        };
      };
      "10-br-lan" = {
        matchConfig.Name = "br-lan";
        networkConfig = {
          Address = "192.168.10.254/24";
        };
      };
    };
  };

  # 测试环境：禁用不必要的服务
  documentation.enable = false;
  documentation.nixos.enable = false;

  # VM 测试需要
  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 4096;  # 宿主 VM 需要足够内存来运行嵌套 microVM
      cores = 4;
      graphics = false;
    };
  };

  # 添加测试工具
  environment.systemPackages = with pkgs; [
    vim
    curl
    tcpdump
  ];

  # 启用 SSH（可选，方便调试）
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  users.users.root.password = "test";
}
