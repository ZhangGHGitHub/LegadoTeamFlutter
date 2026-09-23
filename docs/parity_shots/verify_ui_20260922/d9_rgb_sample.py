# -*- coding: utf-8 -*-
"""D9 深色底色对齐补验：页面/容器底色采样（PIL，可复现）

口径：每个采样点给「中心 + 半边长」小补丁（默认 10x10 px，避开文字/图标），
取补丁内像素 R/G/B 中位数作为该点底色值；与期望值逐通道比对（容差 ±3）。

用法:
  python d9_rgb_sample.py <screenshot.png> <boxes.json>
boxes.json 形如:
  [
    {"label": "书架页面空白区", "center": [x, y], "half": 10,
     "expected": [16, 20, 24]},
    ...
  ]
无 expected 的项只报实测值。
"""
import json
import os
import statistics
import sys

from PIL import Image


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    img_path, boxes_path = sys.argv[1], sys.argv[2]
    im = Image.open(img_path).convert("RGB")
    W, H = im.size
    boxes = json.load(open(boxes_path, encoding="utf-8"))
    print(f"# 采样对象: {img_path} ({W}x{H})")
    print(f"# 口径: 中心 ±{('half 指定或 10')}px 补丁 R/G/B 中位数, 期望容差 ±3/通道")
    print(f"{'采样点':<26s} {'中心':>12s} {'补丁':>6s} {'实测RGB(中位数)':>20s} {'期望RGB':>14s} 判定")
    n_hit = n_fail = n_na = 0
    for b in boxes:
        cx, cy = b["center"]
        half = int(b.get("half", 10))
        x0, y0, x1, y1 = (max(0, cx - half), max(0, cy - half),
                          min(W, cx + half), min(H, cy + half))
        rs, gs, bs = [], [], []
        for y in range(y0, y1):
            for x in range(x0, x1):
                p = im.getpixel((x, y))
                rs.append(p[0]); gs.append(p[1]); bs.append(p[2])
        med = (int(statistics.median(rs)), int(statistics.median(gs)),
               int(statistics.median(bs)))
        exp = b.get("expected")
        if exp is None:
            verdict = "（无期望，仅记录）"
            n_na += 1
        else:
            ok = all(abs(m - e) <= 3 for m, e in zip(med, exp))
            verdict = "命中" if ok else "未命中"
            n_hit += ok
            n_fail += (not ok)
        exp_s = str(exp) if exp is not None else "-"
        print(f"{b['label']:<26s} ({cx:4d},{cy:4d}) {2*half:5d}x{2*half:<2d}  "
              f"({med[0]:3d},{med[1]:3d},{med[2]:3d})    ({exp_s}) {verdict}")
    print(f"== 小计: 命中 {n_hit} / 未命中 {n_fail} / 仅记录 {n_na}")


if __name__ == "__main__":
    main()
