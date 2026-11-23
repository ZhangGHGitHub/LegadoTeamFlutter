from img import load
import numpy as np

CARD_COLORS = ((238,238,238),(240,240,240),(239,239,239),(241,241,241))

def analyze(path, yguess=None):
    a,_ = load(path)
    page = a[500,20].astype(int)
    # flat top edge: y where >=120 px in x range are card-colored
    y0=None
    for y in range(200,1900):
        seg=a[y,200:900].astype(int)
        m=np.all(np.abs(seg-page)<=1,axis=1)  # page pixels
        if (~m).sum()>300 and np.all(np.abs(seg[~m]-np.array([240,240,240]))<=2,axis=1).mean()>0.9:
            y0=y; break
    # left edge at y0+200
    x0=None
    for x in range(0,300):
        c=a[y0+200,x].astype(int)
        if np.abs(c-page).max()>2 and c[0]>200:
            x0=x; break
    # arc profile
    pts=[]
    for y in range(y0, y0+150):
        fx=None
        for x in range(max(0,x0-10), x0+200):
            c=a[y,x].astype(int)
            if np.abs(c-page).max()>2 and c[0]>200:
                fx=x; break
        pts.append((y,x0,fx))
    Rs=[]
    for y,x0v,fx in pts:
        if fx is None: continue
        dx=fx-x0v; dy=y-y0
        if dx>3 and dy>3:
            R=(dx+dy)+ (2*dx*dy)**0.5
            Rs.append(R)
    return dict(y0=y0, x0=x0, n=len(Rs), R_median=float(np.median(Rs)) if Rs else None,
                R_p25=float(np.percentile(Rs,25)) if Rs else None,
                R_p75=float(np.percentile(Rs,75)) if Rs else None)
