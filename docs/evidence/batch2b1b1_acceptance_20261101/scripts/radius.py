from img import load
import numpy as np

def page_bg(a, y=500, x=20):
    return a[y, x].astype(int)

def find_left(a, y, bg, thresh=1.2):
    for x in range(0, 250):
        if np.abs(a[y, x].astype(int) - bg).max() > thresh:
            return x
    return None

def card_tops(a, x, bg, thresh=1.2, ystart=250, yend=1900):
    """transitions page->card along column x"""
    tops = []
    inside = False
    for y in range(ystart, yend):
        diff = np.abs(a[y, x].astype(int) - bg).max() > thresh
        if diff and not inside:
            tops.append(y)
            inside = True
        elif not diff and inside:
            inside = False
    return tops

def radius_at(a, y0, x0, bg, thresh=1.2, span=140):
    pts = []
    for y in range(y0 - 1, y0 + span):
        fx = None
        for x in range(0, x0 + 160):
            if np.abs(a[y, x].astype(int) - bg).max() > thresh:
                fx = x
                break
        pts.append((fx, y))
    arc = [(x, y) for x, y in pts if x is not None and x > x0 + 1]
    best = None
    for R in np.arange(0, 140, 0.25):
        cx, cy = x0 + R, y0 + R
        err = 0; n = 0
        for x, y in arc:
            if y < cy:
                d = np.hypot(x - cx, y - cy) - R
                err += d * d; n += 1
        if n > 8:
            e = err / n
            if best is None or e < best[1]:
                best = (float(R), round(float(e), 3), n)
    return best, pts

def report(path, ymin=250):
    a, _ = load(path)
    bg = page_bg(a)
    x0 = find_left(a, 500, bg)
    tops = card_tops(a, x0 + 6, bg)
    out = []
    for t in tops:
        if t < ymin:
            continue
        fit, _ = radius_at(a, t, x0, bg)
        out.append((t, fit))
    return dict(x0=x0, tops=out)
