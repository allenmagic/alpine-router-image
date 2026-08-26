# Alpine 构建

## 构建命令

```bash
# 基础构建
sudo ./distros/alpine/build.sh

# 构建并打包
sudo PACK=1 ./distros/alpine/build.sh

# 使用镜像源（国内推荐）
sudo REPO=aliyun PACK=1 ./distros/alpine/build.sh
sudo REPO=tuna PACK=1 ./distros/alpine/build.sh

# 自定义参数
sudo BUILD_BASE=/tmp/my-build ROOT_PASSWORD=secret \
  HOSTNAME_VAL=my-router ./distros/alpine/build.sh
```

## 包列表

`distros/alpine/package.list` — 三段式：

| 段 | 内容 |
|----|------|
| base | openssh, chrony, curl, bash, busybox-openrc, dnsmasq, nftables, tailscale, cloudflared(\*)  |
| sing-box | sing-box |
| landscape | （待定） |

(\*) cloudflared 通过 `[dl@URL]` 下载安装。

## 镜像源说明

`REPO` 支持三种形式：
- 不传 → 官方源 `https://dl-cdn.alpinelinux.org/alpine`
- 别名 → `aliyun` / `tuna` / `tsinghua` 自动解析
- 完整 URL → 直接使用

## 产物

- 目录：`build/alpine/alpine-rootfs/`
- 打包：`build/alpine/alpine-rootfs-minimal.tar.xz`（`PACK=1`）
