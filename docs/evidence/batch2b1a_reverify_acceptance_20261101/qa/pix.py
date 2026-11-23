#!/usr/bin/env python3
# Pixel sampling utility for re-verify screenshots (read-only evidence analysis).
import sys
from PIL import Image


def region_stats(path, x1, y1, x2, y2):
    im = Image.open(path).convert("RGB")
    px = im.crop((x1, y1, x2, y2)).load()
    w, h = x2 - x1, y2 - y1
    n = 0
    sr = sg = sb = sr2 = 0
    sat_red = 0
    sat_blue = 0
    colors = {}
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            n += 1
            sr += r; sg += g; sb += b
            sr2 += r * r
            if r > 150 and r - g > 60 and r - b > 60:
                sat_red += 1
            if b > 150 and b - r > 60 and b - g > 30:
                sat_blue += 1
            colors[(r, g, b)] = colors.get((r, g, b), 0) + 1
    mean = (sr / n, sg / n, sb / n)
    var = max(0.0, sr2 / n - mean[0] ** 2)
    std_r = var ** 0.5
    top = sorted(colors.items(), key=lambda kv: -kv[1])[:5]
    return dict(n=n, mean=mean, std_r=std_r, sat_red=sat_red, sat_blue=sat_blue,
                colors=len(colors), top=top)


def line_profile(path, y, x1, x2, step=1):
    im = Image.open(path).convert("RGB")
    px = im.load()
    out = []
    for x in range(x1, x2, step):
        out.append((x, px[x, y]))
    return out


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "region":
        p, x1, y1, x2, y2 = sys.argv[2], *map(int, sys.argv[3:7])
        s = region_stats(p, x1, y1, x2, y2)
        print(f"n={s['n']} mean=({s['mean'][0]:.1f},{s['mean'][1]:.1f},{s['mean'][2]:.1f}) "
              f"stdR={s['std_r']:.1f} satRed={s['sat_red']} satBlue={s['sat_blue']} colors={s['colors']}")
        print("top:", s["top"])
    elif cmd == "px":
        p, x, y = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
        im = Image.open(p).convert("RGB")
        print(im.getpixel((x, y)))
    elif cmd == "row":
        p, y, x1, x2 = sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
        for x, c in line_profile(p, y, x1, x2, 40):
            print(x, c)
    else:
        print("usage: region PATH x1 y1 x2 y2 | px PATH x y | row PATH y x1 x2")
