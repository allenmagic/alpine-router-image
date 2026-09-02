# router-image flake
#
# 提供 nixosModules.router：Alpine Router MicroVM 的消费端声明模块
# （镜像 fetchurl + cloud-hypervisor 声明 + disk-prep + tap 挂桥）。
# 镜像 release 的 tag 与三处 sha256 硬编码在模块内（与本仓库 CI 同源），
# 消费端升级只需 nix flake update。
{
  description = "Alpine router VM image production + microvm consumption module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    microvm.url = "github:astro/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, microvm }:
    let
      system = "x86_64-linux";

      # 宿主侧测试配置（用 microvm.vms.* 管理 VM，需要 NixOS）
      testHostConfig = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          microvm.nixosModules.host
          ./nixos-modules/router.nix
          ./test-microvm.nix
        ];
      };

      # Guest 侧测试配置（独立 microVM，可在任何有 Nix 的系统上运行）
      testGuestConfig = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          microvm.nixosModules.microvm
          ./test-guest.nix
        ];
      };
    in {
    # 消费端模块：qnap-nixos-nas 等宿主引用
    #   imports = [ inputs.router-image.nixosModules.router ];
    #   microvm.router.enable = true;
    nixosModules = {
      router = import ./nixos-modules/router.nix;       # 旧 microvm 模块（T5 移除）
      router-vm = import ./nixos-modules/router-vm.nix; # 新 services.router-vm（T5 起 router 指向它）
    };

    # 测试配置
    nixosConfigurations = {
      test-router = testHostConfig;  # 宿主管理 VM（需要 NixOS）
      test-guest = testGuestConfig;  # 独立 guest（任何系统）

      # NixOS 宿主测试（可以在非 NixOS 上构建 VM 验证）
      test-nixos-host = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          microvm.nixosModules.host
          ./nixos-modules/router.nix
          ./test-nixos-host.nix
        ];
      };
    };

    # 导出 runner 为 package，支持 nix run
    packages.${system} = {
      # 独立 guest runner（推荐：无需 root，无需桥接）
      test-guest-cloud-hypervisor = testGuestConfig.config.microvm.runner.cloud-hypervisor;
      test-guest-qemu = testGuestConfig.config.microvm.runner.qemu;

      # 默认：cloud-hypervisor
      default = testGuestConfig.config.microvm.runner.cloud-hypervisor;
    };
  };
}
