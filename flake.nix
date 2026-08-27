# alpine-router-image flake
#
# 提供 nixosModules.router：Alpine Router MicroVM 的消费端声明模块
# （镜像 fetchurl + cloud-hypervisor 声明 + disk-prep + tap 挂桥）。
# 镜像 release 的 tag 与三处 sha256 硬编码在模块内（与本仓库 CI 同源），
# 消费端升级只需 nix flake update。
{
  description = "Alpine router VM image production + microvm consumption module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }: {
    # 消费端模块：qnap-nixos-nas 等宿主引用
    #   imports = [ inputs.alpine-router-image.nixosModules.router ];
    #   microvm.router.enable = true;
    nixosModules.router = import ./nixos-modules/router.nix;
  };
}
