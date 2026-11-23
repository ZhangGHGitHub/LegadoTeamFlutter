# -*- coding: utf-8 -*-
"""生成本批设备验收夹具（普通图/大图/构造 .9）。"""
import os
import shutil
import struct
import zlib

from PIL import Image, ImageDraw, ImageFont

BASE = r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261103_batch2b1b2b\fixtures"
SRC = r"D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\test\fixtures"
os.makedirs(BASE, exist_ok=True)


def chunk(typ, data):
    return (struct.pack(">I", len(data)) + typ + data +
            struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))


def inject_nptc(png_path, xdivs, ydivs, num_colors=0):
    """在 IHDR 后插入 npTc（文件序列化格式，byte0=0）。"""
    raw = open(png_path, "rb").read()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n"
    # 拆块
    chunks = []
    i = 8
    while i < len(raw):
        ln = struct.unpack(">I", raw[i:i + 4])[0]
        typ = raw[i + 4:i + 8]
        data = raw[i + 8:i + 8 + ln]
        chunks.append((typ, data))
        i += 12 + ln
    # 构造 npTc
    num_x, num_y = len(xdivs), len(ydivs)
    header_len = 32
    xo = header_len
    yo = xo + 4 * num_x
    co = yo + 4 * num_y
    payload = bytearray()
    payload += struct.pack("<BBBB", 0, num_x, num_y, num_colors)
    payload += struct.pack("<i", xo)
    payload += struct.pack("<i", yo)
    payload += struct.pack("<iiii", 0, 0, 0, 0)
    payload += struct.pack("<i", co if num_colors else 0)
    payload += b"".join(struct.pack(">i", v) for v in xdivs)
    payload += b"".join(struct.pack(">i", v) for v in ydivs)
    payload += b"".join(struct.pack(">I", 0xFFFFFFFF) for _ in range(num_colors))
    np = chunk(b"npTc", bytes(payload))
    out = bytearray(raw[:8])
    for typ, data in chunks:
        if typ == b"npTc":
            continue
        out += chunk(typ, data)
        if typ == b"IHDR":
            out += np
    open(png_path, "wb").write(out)


def quadrant(path, size=(600, 300), fmt="PNG"):
    w, h = size
    im = Image.new("RGB", size)
    dr = ImageDraw.Draw(im)
    dr.rectangle([0, 0, w // 2 - 1, h // 2 - 1], fill=(220, 40, 40))      # 红
    dr.rectangle([w // 2, 0, w - 1, h // 2 - 1], fill=(40, 160, 60))      # 绿
    dr.rectangle([0, h // 2, w // 2 - 1, h - 1], fill=(40, 80, 220))      # 蓝
    dr.rectangle([w // 2, h // 2, w - 1, h - 1], fill=(240, 200, 40))     # 黄
    dr.line([w // 2, 0, w // 2, h], fill=(0, 0, 0), width=3)
    dr.line([0, h // 2, w, h // 2], fill=(0, 0, 0), width=3)
    dr.ellipse([w // 2 - 40, h // 2 - 40, w // 2 + 40, h // 2 + 40],
               outline=(0, 0, 0), width=4)
    im.save(path, fmt, quality=92)


def nine_patch_diag(path, size=120, border=20):
    """构造可判别 .9 拉伸的图：角黄、上下边蓝、左右边绿、中心品红+黑 X。"""
    im = Image.new("RGB", (size, size), (255, 0, 255))
    dr = ImageDraw.Draw(im)
    # 四条边带（不属于角）
    dr.rectangle([border, 0, size - border - 1, border - 1], fill=(30, 90, 255))
    dr.rectangle([border, size - border, size - border - 1, size - 1], fill=(30, 90, 255))
    dr.rectangle([0, border, border - 1, size - border - 1], fill=(0, 180, 60))
    dr.rectangle([size - border, border, size - 1, size - border - 1], fill=(0, 180, 60))
    # 四角
    for x0, y0 in [(0, 0), (size - border, 0), (0, size - border), (size - border, size - border)]:
        dr.rectangle([x0, y0, x0 + border - 1, y0 + border - 1], fill=(255, 230, 0))
    # 中心黑 X
    dr.line([border, border, size - border - 1, size - border - 1], fill=(0, 0, 0), width=6)
    dr.line([size - border - 1, border, border, size - border - 1], fill=(0, 0, 0), width=6)
    im.save(path, "PNG")
    inject_nptc(path, [border, size - border], [border, size - border])


def solid_png(path, size, color=(90, 140, 200)):
    Image.new("RGB", size, color).save(path, "PNG")


def main():
    # 1) 仓库真实 .9 夹具（ASCII 重命名）
    for src, dst in [
        ("nine_patch_0x.9.png", "qa_nine_0x.9.png"),
        ("nine_patch_1J.9.png", "qa_nine_1J.9.png"),
        ("nine_patch_source_no_nptc.9.png", "qa_nine_src.9.png"),
    ]:
        shutil.copyfile(os.path.join(SRC, src), os.path.join(BASE, dst))
    # 2) 普通 PNG/JPG
    quadrant(os.path.join(BASE, "qa_plain.png"))
    quadrant(os.path.join(BASE, "qa_plain.jpg"), fmt="JPEG")
    # 3) 可判别九宫格（构造，npTc 单区域）
    nine_patch_diag(os.path.join(BASE, "qa_diag.9.png"))
    # 4) 源码形态（无 npTc）的同图，用于回落对照
    nine_patch_diag(os.path.join(BASE, "qa_diag_src.9.png"))
    # 移除 npTc 模拟源码形态
    raw = open(os.path.join(BASE, "qa_diag_src.9.png"), "rb").read()
    i = 8
    out = bytearray(raw[:8])
    while i < len(raw):
        ln = struct.unpack(">I", raw[i:i + 4])[0]
        typ = raw[i + 4:i + 8]
        data = raw[i + 8:i + 8 + ln]
        if typ != b"npTc":
            out += chunk(typ, data)
        i += 12 + ln
    open(os.path.join(BASE, "qa_diag_src.9.png"), "wb").write(out)
    # 5) 12MP 普通 JPG（4000x3000）
    im = Image.new("RGB", (4000, 3000))
    dr = ImageDraw.Draw(im)
    for y in range(0, 3000, 30):
        dr.line([0, y, 4000, y], fill=(y % 255, (y * 3) % 255, 200), width=30)
    dr.rectangle([1900, 1400, 2100, 1600], fill=(255, 0, 0))
    im.save(os.path.join(BASE, "qa_big12mp.jpg"), "JPEG", quality=85)
    # 6) 12MP 构造 .9（4000x3000，单区域）
    im = Image.new("RGB", (4000, 3000), (200, 60, 60))
    dr = ImageDraw.Draw(im)
    dr.rectangle([0, 0, 4000, 200], fill=(255, 255, 0))
    dr.rectangle([0, 0, 200, 3000], fill=(0, 255, 0))
    dr.rectangle([3800, 0, 4000, 3000], fill=(0, 0, 255))
    dr.rectangle([0, 2800, 4000, 3000], fill=(255, 255, 255))
    im.save(os.path.join(BASE, "qa_big12mp.9.png"), "PNG")
    inject_nptc(os.path.join(BASE, "qa_big12mp.9.png"), [300, 3700], [300, 2700])
    # 7) >32MP .9（7000x5000=35MP，单区域）
    p = os.path.join(BASE, "qa_huge35mp.9.png")
    solid_png(p, (7000, 5000), (120, 80, 200))
    inject_nptc(p, [300, 6700], [300, 4700])
    # 8) 单边 >8192 的 .9（9000x100，0.9MP）
    p = os.path.join(BASE, "qa_long9k.9.png")
    solid_png(p, (9000, 100), (30, 180, 180))
    inject_nptc(p, [100, 8900], [20, 80])
    for n in sorted(os.listdir(BASE)):
        fp = os.path.join(BASE, n)
        print("%-28s %10d B" % (n, os.path.getsize(fp)))


if __name__ == "__main__":
    main()
