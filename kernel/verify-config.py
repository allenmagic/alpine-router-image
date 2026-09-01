#!/usr/bin/env python3
"""config 片段生效校验。

片段（config.fragment）经 allnoconfig + olddefconfig 后，任何一条因依赖
未满足而被静默丢弃的项都可能造成「能编译但不可引导」的内核——本脚本逐条
比对片段声明与最终 .config，不一致即非零退出。

用法: verify-config.py <config.fragment> <.config>
"""
import re
import sys

SET = re.compile(r"^(CONFIG_[A-Z0-9_]+)=(.+)$")
UNSET = re.compile(r"^# (CONFIG_[A-Z0-9_]+) is not set$")


def parse(path, keep_comment_unset):
    """→ {symbol: value}；value 为 'n' 表示要求关闭。"""
    want = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            m = SET.match(line)
            if m:
                want[m.group(1)] = m.group(2)
                continue
            m = UNSET.match(line)
            if m and keep_comment_unset:
                want[m.group(1)] = "n"
    return want


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    frag, dotconfig = sys.argv[1], sys.argv[2]

    # 片段里 "# CONFIG_X is not set" 是显式要求关闭，需要校验
    want = parse(frag, keep_comment_unset=True)
    # .config 里同样形式表示实际关闭
    got = parse(dotconfig, keep_comment_unset=True)

    missing, wrong = [], []
    for sym, val in sorted(want.items()):
        actual = got.get(sym)
        if actual is None:
            # 片段要求关闭、.config 里符号完全不存在（依赖未满足而不可见）→ 视为满足
            if val == "n":
                continue
            missing.append(sym)
        elif actual != val:
            wrong.append((sym, val, actual))

    if not missing and not wrong:
        print(f"[verify] OK：片段 {len(want)} 项全部生效")
        return 0

    if missing:
        print(f"[verify] ❌ 未生效（依赖未满足，被静默丢弃）{len(missing)} 项：")
        for sym in missing:
            print(f"    {sym}")
    if wrong:
        print(f"[verify] ❌ 取值不符 {len(wrong)} 项：")
        for sym, val, actual in wrong:
            print(f"    {sym}: 期望 {val}，实际 {actual}")
    print("[verify] 修复片段（补依赖或删除该项）后重试")
    return 1


if __name__ == "__main__":
    sys.exit(main())
