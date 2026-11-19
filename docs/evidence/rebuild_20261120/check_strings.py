"""Verify HLS fix strings are embedded in rebuilt .so binaries.

Reads each .so as raw bytes and searches for the UTF-8 encoding of each needle.
Reports hit/miss per (string, ABI) pair plus the byte offset of the first hit.
"""
import hashlib
import os
import sys

NEEDLES = [
    "HLS 初始化段下载失败",
    "HLS 变体播放列表仍为 master",
    "EXT-X-BYTERANGE 偏移与长度之和溢出",
    "HLS 合并产物超出体积上限",
    "直播流不支持离线缓存",
]

ABIS = ["arm64-v8a", "armeabi-v7a", "x86_64"]
JNI = os.path.join(
    "D:\\OH-WorkSpace\\LegadoTeam\\legado",
    "flutter_legado", "android", "app", "src", "main", "jniLibs",
)

results = {}
for abi in ABIS:
    path = os.path.join(JNI, abi, "liblegado_ffi.so")
    with open(path, "rb") as fh:
        blob = fh.read()
    digest = hashlib.sha256(blob).hexdigest()
    print(f"== {abi} ==")
    print(f"   path   : {path}")
    print(f"   size   : {len(blob)} bytes")
    print(f"   sha256 : {digest}")
    for needle in NEEDLES:
        raw = needle.encode("utf-8")
        idx = blob.find(raw)
        if idx >= 0:
            count = blob.count(raw)
            results[(abi, needle)] = ("HIT", idx, count)
            print(f"   [HIT ] 0x{idx:08x} x{count}  {needle}")
        else:
            results[(abi, needle)] = ("MISS", -1, 0)
            print(f"   [MISS]              {needle}")
    print()

print("== matrix ==")
header = "%-38s %-14s %-14s %-14s" % ("STRING", *ABIS)
print(header)
print("-" * len(header))
all_ok = True
for needle in NEEDLES:
    row = ["%-14s" % results[(abi, needle)][0] for abi in ABIS]
    if any(results[(abi, needle)][0] != "HIT" for abi in ABIS):
        all_ok = False
    print("%-38s %s" % (needle, " ".join(row)))

print()
print("RESULT=" + ("PASS" if all_ok else "FAIL"))
sys.exit(0 if all_ok else 1)
