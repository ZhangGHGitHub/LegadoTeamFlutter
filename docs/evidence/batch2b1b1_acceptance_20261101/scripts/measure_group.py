from img import load
import numpy as np

CARD = (240,240,240)

def tops(a, ystart=200, yend=1915):
    out=[]; inside=False
    for y in range(ystart,yend):
        seg=a[y,200:900].astype(int)
        cardish=np.all(np.abs(seg-np.array(CARD))<=2,axis=1)
        if cardish.mean()>0.9:
            if not inside: out.append(y); inside=True
        else: inside=False
    return out

def radius(a, y0, page):
    ymid=min(y0+200,1915)
    x0=None
    for x in range(0,300):
        c=a[ymid,x].astype(int)
        if np.abs(c-page).max()>2 and c[0]>200: x0=x; break
    if x0 is None: return None
    Rs=[]
    for y in range(y0,min(y0+150,1915)):
        fx=None
        for x in range(max(0,x0-10),x0+200):
            c=a[y,x].astype(int)
            if np.abs(c-page).max()>2 and c[0]>200: fx=x; break
        if fx is None: continue
        dx=fx-x0; dy=y-y0
        if dx>3 and dy>3: Rs.append((dx+dy)+(2*dx*dy)**0.5)
    if not Rs: return 0.0
    return round(float(np.median(Rs)),1)

def measure(path):
    a,_=load(path)
    page=a[500,20].astype(int)
    res=[]
    for t in tops(a):
        r=radius(a,t,page)
        if r is not None and r<160:
            res.append((t, r))
    return res
