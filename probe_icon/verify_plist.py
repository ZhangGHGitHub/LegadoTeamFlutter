#!/usr/bin/env python3
"""校验探针 App 落盘结构：必须是纯 legacy（CFBundleIconFiles，无 CFBundleIconName）。

用法：python3 verify_plist.py <Runner.app/Info.plist>
退出码 0=通过；断言失败时非零退出并打印原因。
"""
import plistlib
import sys


def main() -> int:
    path = sys.argv[1]
    with open(path, "rb") as f:
        d = plistlib.load(f)
    alt = (d.get("CFBundleIcons") or {}).get("CFBundleAlternateIcons", {})
    assert alt, "CFBundleAlternateIcons 缺失"
    probe = alt.get("probe")
    assert probe and "CFBundleIconFiles" in probe, "probe 条目缺 CFBundleIconFiles"
    assert "CFBundleIconName" not in probe, "probe 不应含 CFBundleIconName（须纯 legacy）"
    print("OK: probe =", probe)
    return 0


if __name__ == "__main__":
    sys.exit(main())
