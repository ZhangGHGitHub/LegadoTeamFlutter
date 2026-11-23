from img import load
import numpy as np

def card_top(a, xr=(200,900)):
    for y in range(250,900):
        seg=a[y,xr[0]:xr[1]].astype(int)
        if np.all(np.abs(seg-np.array([240,240,240]))<=2,axis=1).mean()>0.9:
            return y
    return None

def first_text_y(a, y0, xr=(220,700), maxd=260, thr=120):
    for y in range(y0, min(y0+maxd, a.shape[0])):
        seg=a[y,xr[0]:xr[1]].astype(int)
        dark=(seg.mean(axis=1)<thr)
        if dark.sum()>5:
            return y
    return None

def report(path):
    a,_=load(path)
    y0=card_top(a)
    ty=first_text_y(a,y0) if y0 else None
    # left/right card edges at y0+120
    page=a[500,20].astype(int)
    ymid=y0+120
    x0=None
    for x in range(0,300):
        if np.abs(a[ymid,x].astype(int)-page).max()>2: x0=x;break
    x1=None
    for x in range(1079,700,-1):
        if np.abs(a[ymid,x].astype(int)-page).max()>2: x1=x;break
    return dict(card_top=y0, first_text_y=ty, text_offset=(ty-y0 if ty and y0 else None), x0=x0, x1=x1, width=(x1-x0+1 if x0 and x1 else None))
