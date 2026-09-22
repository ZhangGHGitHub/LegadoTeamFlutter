# -*- coding: utf-8 -*-
"""P2-21 补验：三行块文字墨色采样（PIL，可复现）
用法: python b8_rgb_sample.py > b8_rgb_sample.txt
对每个 dump bounds 框，取亮度>=阈值的“墨水”像素，输出 R/G/B 中位数。
深色背景下文字为亮像素；绿主题 accent 亮度亦 >130，可一并捕获。
"""
import os, statistics
from PIL import Image

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(BASE, ".."))
OURS = os.path.join(BASE, "b8_a1_detail.png")
REF = os.path.join(ROOT, "ref_dark_20260920", "08_book_info.png")

LUM_LO = 130  # 墨水像素亮度下限（深底亮字）


def lum(px):
    r, g, b = px[0], px[1], px[2]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def sample(im, box, label):
    x0, y0, x1, y1 = box
    W, H = im.size
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(W, x1), min(H, y1)
    px = im.convert("RGBA")
    rs, gs, bs = [], [], []
    for y in range(y0, y1):
        for x in range(x0, x1):
            p = px.getpixel((x, y))
            if lum(p) >= LUM_LO:
                rs.append(p[0]); gs.append(p[1]); bs.append(p[2])
    if not rs:
        print(f"{label:24s} box={box}  ink_pixels=0 (无采样)")
        return
    print(f"{label:24s} box={box}  ink_pixels={len(rs)} "
          f"median_rgb=({int(statistics.median(rs))},"
          f"{int(statistics.median(gs))},{int(statistics.median(bs))})")


def main():
    ours = Image.open(OURS)
    ref = Image.open(REF)
    print("== 采样口径: 框内亮度>=%d 像素的 R/G/B 中位数 (1080x1920, dark)" % LUM_LO)
    print("-- 我方 b8_a1_detail.png (场景A: dt=引子 测试标题 / lt=测试最新章 / dci=1 / 共3章)")
    sample(ours, (39, 1194, 479, 1266), "在读行  '在读 · 引子 测试标题'")
    sample(ours, (39, 1284, 346, 1341), "最新行  '最新 · 测试最新章'")
    sample(ours, (39, 1377, 153, 1431), "共N章  '共 3 章'")
    sample(ours, (177, 1379, 187, 1430), "分隔符 '|'")
    sample(ours, (211, 1377, 361, 1431), "状态  '已读 2 章'")
    print("-- 参考 ref_dark_20260920/08_book_info.png (711章书)")
    sample(ref, (48, 1375, 636, 1447), "在读行  '在读 · …'")
    sample(ref, (48, 1459, 1032, 1580), "最新行  '最新 · …'(2行折行)")
    sample(ref, (48, 1596, 211, 1648), "共N章  '共711章'")
    sample(ref, (235, 1592, 246, 1652), "分隔符 '|'")
    sample(ref, (270, 1596, 425, 1648), "状态  '已读1章'")
    print("-- 背景参考 (非文字区)")
    sample(ours, (600, 1194, 700, 1266), "我方 背景(在读行右侧)")
    sample(ref, (600, 1375, 700, 1447), "参考 背景(在读行右侧)")


if __name__ == "__main__":
    main()
