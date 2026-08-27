# Alpine Router MicroVM 消费端声明模块（POC）
#
# 由 qnap-nixos-nas 的 microvm/router.nix 迁移而来（2026-08-27）。
# 镜像生产与消费同仓库：CI 出 release 时同步更新本文件的 tag 与三处 sha256，
# 宿主侧升级只需 nix flake update，无手动同步。
#
# 用法：
#   imports = [ inputs.alpine-router-image.nixosModules.router ];
#   microvm.router.enable = true;   # 可选参数覆盖见 options
#
# 供应链：
#   - 镜像资产由本仓库 CI 生产（release asset）：vmlinuz-virt / initrd（注入
#     ext4 依赖链）/ alpine-router-rootfs.qcow2，本模块只 fetchurl 拉取
#   - disk-prep 服务把 release 镜像复制到 /var/lib/alpine-router（可写状态目录；
#     store 只读无法直接读写打开）——release 升级（store 路径变化）自动重装状态
#   - 配置：alpine-router-deploy（NAS 侧）是唯一密钥注入通道，配置已烙进镜像
#
# 后端与资源（cloud-hypervisor）：
#   - cpu 核隔离：isolcpus + vcpu0 affinity pin（宿主机不再使用该核）
#   - 动态内存：virtio-balloon（CH 128M 对齐粒度）+ 宿主 OOM 放气
#   - 网络：CH 无 qemu 的 bridge 接口类型，用 tap 接口 + systemd-networkd
#     在 tap 出现时自动加入桥
{ config, lib, pkgs, ... }:

let
  cfg = config.microvm.router;

  # 本仓库 CI release（升级时同步改 tag 与三处 sha256，
  # 真实值取 release 的 SHA256SUMS asset）
  imageRelease = "alpine-router-image-20260826";
  releaseBase = "https://github.com/allenmagic/alpine-router-image/releases/download/${imageRelease}";

  # 客户机内核包装：CH runner（x86_64 分支）取 ${kernel.dev}/vmlinux——
  # 内容实为 bzImage（官方 vmlinuz-virt），CH 按文件头自动识别加载
  alpineKernel = pkgs.runCommand "vmlinuz-virt" { outputs = [ "out" "dev" ]; } ''
    mkdir -p $out $dev
    cp ${cfg.kernelFile} $out/bzImage
    cp ${cfg.kernelFile} $dev/vmlinux
  '';

  # 状态盘路径带镜像内容哈希：镜像更新 → 路径变 → ExecStart 变 → VM 必然重启
  # （volumes.image 固定路径不在 restartIfChanged 检测内，此前依赖 initrd
  # store 路径碰巧变化才重启）；旧镜像文件保留，rollback 时旧 generation
  # 直接指向旧镜像，无需重新复制
  imgId = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toString cfg.rootfsImage));
  stateImage = "/var/lib/alpine-router/rootfs-${imgId}.qcow2";
in

{
  options.microvm.router = {
    enable = lib.mkEnableOption "Alpine Router MicroVM（POC，与 libvirt 方案二选一）";

    kernelFile = lib.mkOption {
      type = lib.types.path;
      default = pkgs.fetchurl {
        url = "${releaseBase}/vmlinuz-virt";
        sha256 = "1e6bf9027720c75c3ed0d79171f21b5791ee40ca9795d07c7c6e04dc5ea2ae90";
      };
      description = ''
        Alpine 官方 vmlinuz-virt（本仓库 release asset）。
        本地调试可用 image/assemble.sh 产物的 vmlinuz-virt 覆盖。
      '';
    };

    initrd = lib.mkOption {
      type = lib.types.path;
      default = pkgs.fetchurl {
        url = "${releaseBase}/initrd";
        sha256 = "e32522f9ae486522348e69343941a1d01a194945604d8fa7518b11346953002c";
      };
      description = ''
        装配后的 initramfs（已注入 ext4 依赖链，本仓库 release asset）。
      '';
    };

    rootfsImage = lib.mkOption {
      type = lib.types.path;
      default = pkgs.fetchurl {
        url = "${releaseBase}/alpine-router-rootfs.qcow2";
        sha256 = "7b5810ed4a6ac1371a51f7d4d0043242add3f513ab2220fd79c22d6b515b0dd5";
      };
      description = ''
        VM 根磁盘 qcow2（rootfs + modloop 模块，本仓库 release asset）。
      '';
    };

    cpu = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 3;
      description = ''
        隔离给路由器 VM 独占的宿主核号（isolcpus + vcpu0 affinity）。
        注意：isolcpus 影响整个宿主——修改时确认宿主的核数。
      '';
    };

    mem = lib.mkOption {
      type = lib.types.ints.positive;
      default = 512;
      description = "guest 内存上限（MB）";
    };

    initialBalloonMem = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 256;
      description = ''
        初始 balloon 大小（MB，CH 要求 128M 对齐）；宿主 OOM 时自动放气归还。
      '';
    };

    wanBridge = lib.mkOption {
      type = lib.types.str;
      default = "br-wan";
      description = "WAN 侧宿主网桥（tap 自动挂入）";
    };

    lanBridge = lib.mkOption {
      type = lib.types.str;
      default = "br-lan";
      description = "LAN 侧宿主网桥（tap 自动挂入）";
    };
  };

  config = lib.mkIf cfg.enable {
    # CPU 独占：指定核隔离给路由器 VM（宿主调度器不再使用该核）
    boot.kernelParams = [ "isolcpus=${toString cfg.cpu}" "rcu_nocbs=${toString cfg.cpu}" ];

    # 首次启动 / 镜像更新时把 release 镜像复制到可写状态目录。
    # 文件名含内容哈希：不存在才复制（幂等）；旧版本镜像文件保留
    # 供 rollback 复用，可手动清理
    systemd.services.alpine-router-disk = {
      wantedBy = [ "multi-user.target" ];
      requiredBy = [ "microvm@alpine-router.service" ];
      before = [ "microvm@alpine-router.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        STATE_DIR=/var/lib/alpine-router
        STATE_IMG=${stateImage}
        mkdir -p "$STATE_DIR"
        if [ ! -f "$STATE_IMG" ]; then
          echo "初始化 VM 根磁盘: ${cfg.rootfsImage} -> $STATE_IMG"
          install -m 0644 "${cfg.rootfsImage}" "$STATE_IMG"
        fi
      '';
    };

    # CH 的 tap 接口由 microvm 在 VM 启动时创建，networkd 在接口出现时
    # 自动将其加入对应桥（bridge 接口类型是 qemu 特有，CH 不支持）
    systemd.network.networks = {
      "50-router-wan" = {
        matchConfig.Name = "router-wan";
        networkConfig.Bridge = cfg.wanBridge;
      };
      "50-router-lan" = {
        matchConfig.Name = "router-lan";
        networkConfig.Bridge = cfg.lanBridge;
      };
    };

    microvm.vms.alpine-router = {
      autostart = true;
      # 注意：config 是单个 NixOS 模块（非列表），VM 内选项挂在 microvm.* 下
      config = {
        microvm.hypervisor = "cloud-hypervisor";

        microvm.vcpu = 2;   # vcpu0 独占隔离核；vcpu1 动态
        microvm.mem = cfg.mem;

        # 动态内存：virtio-balloon（CH 要求 128M 对齐粒度）。
        # 备选：virtio-mem 热插拔（hotplugMem），可 ch-remote 手动伸缩
        microvm.balloon = true;
        microvm.initialBalloonMem = cfg.initialBalloonMem;
        microvm.deflateOnOOM = true;

        # vcpu0 affinity（--cpus boot=N 由 microvm 生成，affinity 经 extraArgs 合并）
        # 语法：CH v53 用 vcpu@[host_cpus] 格式（WSL 实测验证）
        microvm.cloud-hypervisor.extraArgs = [
          "--cpus" "affinity=[0@[${toString cfg.cpu}]]"
        ];

        # vsock（0=hypervisor 1=loopback 2=host 保留，guest 从 3 起）。
        # 注：microvm -s 的 vsock SSH 需要 guest 侧监听 vsock 的 sshd
        # （Alpine 默认只监听 TCP），此处先占 CID 供将来扩展
        microvm.vsock.cid = 3;

        # 客户机内核 / initramfs（官方 virt 三件套，装配时注入 ext4 依赖链）
        microvm.kernel = alpineKernel;
        microvm.initrdPath = "${cfg.initrd}";
        # rootfstype=ext4：initramfs 的 "Loading boot drivers" 会据此 modprobe ext4
        microvm.kernelParams = [ "root=/dev/vda" "rootfstype=ext4" "rw" ];

        microvm.volumes = [{
          # vda：根卷（disk-prep 维护的可写状态副本，路径含内容哈希）
          image = stateImage;
          mountPoint = "/";
          autoCreate = false;
          imageType = "qcow2";   # CH 的 --disk 默认 image_type=raw，必须显式声明
        }];

        # tap 由 microvm 创建，networkd 挂进宿主桥
        microvm.interfaces = [
          { type = "tap"; id = "router-wan"; mac = "02:00:00:01:00:01"; }
          { type = "tap"; id = "router-lan"; mac = "02:00:00:01:00:02"; }
        ];
      };
    };
  };
}
