"""QA pixel analysis helpers (batch 2b-1b-1)."""
import sys
from PIL import Image
import numpy as np


def load(path):
    im = Image.open(path).convert('RGB')
    return np.array(im), im.size


def row_colors(a, y, x0, x1, step=1):
    out = []
    for x in range(x0, x1, step):
        out.append((x, tuple(int(v) for v in a[y, x])))
    return out


def col_colors(a, x, y0, y1, step=1):
    out = []
    for y in range(y0, y1, step):
        out.append((y, tuple(int(v) for v in a[y, x])))
    return out


def runs(seq):
    """Group consecutive identical colors: seq = [(pos, (r,g,b))]"""
    out = []
    cur = None
    for pos, c in seq:
        if cur and cur[2] == c:
            cur = (cur[0], pos, c, cur[3] + 1)
        else:
            if cur:
                out.append(cur)
            cur = (pos, pos, c, 1)
    if cur:
        out.append(cur)
    return out


def card_top_edge(a, x, y0, y1, bg_tol=3):
    """First y where color differs from background sample at (y0,x)."""
    bg = a[y0, x].astype(int)
    for y in range(y0, y1):
        d = np.abs(a[y, x].astype(int) - bg).max()
        if d > bg_tol:
            return y
    return None


def card_left_edge(a, y, x0, x1, bg_tol=3):
    bg = a[y, x0].astype(int)
    for x in range(x0, x1):
        d = np.abs(a[y, x].astype(int) - bg).max()
        if d > bg_tol:
            return x
    return None


def corner_profile(a, x_edge, y_edge, bg_sample_xy, length=80):
    """For each y from y_edge..y_edge+length, measure first x where card color starts."""
    bx, by = bg_sample_xy
    bg = a[by, bx].astype(int)
    prof = []
    for y in range(y_edge, y_edge + length):
        x = None
        for xx in range(x_edge - 5, x_edge + length):
            if np.abs(a[y, xx].astype(int) - bg).max() > 3:
                x = xx
                break
        prof.append((y, x))
    return prof


if __name__ == '__main__':
    p = sys.argv[1]
    a, size = load(p)
    print('size', size)
