"""Pixel analysis helpers for batch 2b-1b-2a acceptance.

Commands:
  bands <png> <x> [channel]      print vertical color bands at column x
  sample <png> <x> <y> [n]       print pixel color (median of n x n)
  redrows <png> [x]              print rows where pixel is strongly red at x
  region <png> x1 y1 x2 y2      print top colors in region
"""
import sys
from collections import Counter

from PIL import Image


def med(img, x, y, n=1):
    px = []
    for yy in range(max(0, y - n), min(img.height, y + n + 1)):
        for xx in range(max(0, x - n), min(img.width, x + n + 1)):
            px.append(img.getpixel((xx, yy))[:3])
    r = sorted(p[0] for p in px)
    g = sorted(p[1] for p in px)
    b = sorted(p[2] for p in px)
    return (r[len(r) // 2], g[len(g) // 2], b[len(b) // 2])


def main():
    cmd = sys.argv[1]
    path = sys.argv[2]
    img = Image.open(path).convert('RGB')
    if cmd == 'sample':
        x, y = int(sys.argv[3]), int(sys.argv[4])
        n = int(sys.argv[5]) if len(sys.argv) > 5 else 1
        print(med(img, x, y, n))
    elif cmd == 'redrows':
        x = int(sys.argv[3]) if len(sys.argv) > 3 else img.width // 2
        rows = []
        for y in range(img.height):
            r, g, b = img.getpixel((x, y))
            if r > 180 and g < 100 and b < 100:
                rows.append(y)
        # compress consecutive
        out = []
        start = prev = None
        for y in rows:
            if start is None:
                start = prev = y
            elif y == prev + 1:
                prev = y
            else:
                out.append((start, prev))
                start = prev = y
        if start is not None:
            out.append((start, prev))
        print('x=%d red bands: %s' % (x, out))
        for a, b in out:
            print('  y=%d..%d h=%d colors=%s' %
                  (a, b, b - a + 1,
                   Counter(img.getpixel((x, y)) for y in range(a, b + 1))
                   .most_common(3)))
    elif cmd == 'bands':
        x = int(sys.argv[3])
        prev = None
        start = 0
        for y in range(img.height):
            c = img.getpixel((x, y))
            # quantize to reduce AA noise
            q = tuple(v // 8 * 8 for v in c)
            if q != prev:
                if prev is not None:
                    print('y=%d..%d h=%d %s' % (start, y - 1, y - start, prev))
                start = y
                prev = q
        print('y=%d..%d h=%d %s' % (start, img.height - 1,
                                    img.height - start, prev))
    elif cmd == 'region':
        x1, y1, x2, y2 = (int(v) for v in sys.argv[3:7])
        c = Counter()
        for y in range(y1, y2):
            for x in range(x1, x2):
                c[img.getpixel((x, y))] += 1
        for col, n in c.most_common(8):
            print(col, n)
    else:
        print('unknown')
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
