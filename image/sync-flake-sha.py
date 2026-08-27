#!/usr/bin/env python3
# 从 dist/SHA256SUMS 同步 nixos-modules/router.nix 的 release tag 与三处 sha256
# 用法：python3 image/sync-flake-sha.py <SHA256SUMS> <router.nix> <release-tag>
# 幂等：值相同则文件不变（git diff 为空，调用方跳过提交）
import re
import sys

sha_file, nix_file, tag = sys.argv[1], sys.argv[2], sys.argv[3]

shas = {}
for line in open(sha_file):
    parts = line.split()
    if len(parts) == 2:
        shas[parts[1]] = parts[0]

s = open(nix_file).read()

# 更新 tag（幂等：同日重跑值不变）
s, n_tag = re.subn(r'imageRelease = "[^"]*";', f'imageRelease = "{tag}";', s, count=1)
if n_tag == 0:
    sys.exit("imageRelease 行未找到")

# 更新三处 sha256（锚定对应 url 行之后的 sha256 行）
for asset in ("vmlinuz-virt", "initrd", "alpine-router-rootfs.qcow2"):
    sha = shas.get(asset)
    if not sha:
        sys.exit(f"SHA256SUMS 缺少 {asset}")
    pattern = re.compile(
        r'(url = "\$\{releaseBase\}/' + asset + r'";\n\s*sha256 = ")[0-9a-f]{64}(")'
    )
    s, n = pattern.subn(r"\g<1>" + sha + r"\g<2>", s, count=1)
    if n == 0:
        sys.exit(f"{asset} 的 sha256 行未找到")

open(nix_file, "w").write(s)
print(f"已同步 {tag}: vmlinuz={shas['vmlinuz-virt'][:12]}... "
      f"initrd={shas['initrd'][:12]}... qcow2={shas['alpine-router-rootfs.qcow2'][:12]}...")
