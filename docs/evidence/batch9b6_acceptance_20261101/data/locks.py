#!/usr/bin/env python
"""Capture wake/wifi lock state evidence from the MuMu device."""
import os
import re
import subprocess
import sys
import time

ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
SERIAL = "192.168.100.62:5555"
BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(BASE, "..", "logcat"))

PAT = re.compile(
    r"legado:WebService|Wake Locks|WifiLock\{|full_high_perf|acquireWifiLock|releaseWifiLock",
    re.I,
)


def dump(service):
    r = subprocess.run(
        [ADB, "-s", SERIAL, "shell", "dumpsys", service],
        capture_output=True,
        timeout=120,
    )
    return (r.stdout or b"").decode("utf-8", "replace")


def main():
    label = sys.argv[1] if len(sys.argv) > 1 else time.strftime("%H%M%S")
    os.makedirs(OUT, exist_ok=True)
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print("=== %s @ %s" % (label, ts))
    for svc in ("power", "wifi"):
        text = dump(svc)
        path = os.path.join(OUT, "%s_%s.txt" % (svc, label))
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        # active lock lines only (skip old logcat noise in wifi dump)
        lines = text.splitlines()
        hits = []
        for i, line in enumerate(lines):
            if re.match(r"\s*11-\d\d \d\d:\d\d:\d\d", line):
                # log lines appear only in wifi dump; keep only acquire/release
                if not re.search(r"(acquire|release)WifiLock", line, re.I):
                    continue
            if PAT.search(line):
                hits.append((i + 1, line.strip()))
        print("--- %s (%d lines, file %s)" % (svc, len(lines), os.path.basename(path)))
        if not hits:
            print("  NO MATCH (no active legado lock)")
        for ln, line in hits[:20]:
            print("  %d: %s" % (ln, line[:220]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
