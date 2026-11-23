#!/usr/bin/env bash
# 截图助手：./shot.sh <标签>
set -uo pipefail
cd "$(dirname "$0")"
TAG="${1:-shot}"
export PATH="/d/Program Files/MuMuPlayer/nx_main:$PATH"
export MSYS_NO_PATHCONV=1
SERIAL=192.168.100.62:5555
adb -s "$SERIAL" exec-out screencap -p > "screens/${TAG}.png" 2>/dev/null
python - "screens/${TAG}.png" <<'PY'
import sys, struct
p = sys.argv[1]
with open(p, 'rb') as f:
    data = f.read()
ok = data[:8] == b'\x89PNG\r\n\x1a\n'
w = h = 0
if ok and len(data) >= 24:
    w, h = struct.unpack('>II', data[16:24])
print(f"{p}: {len(data)} bytes png={ok} {w}x{h}")
PY
