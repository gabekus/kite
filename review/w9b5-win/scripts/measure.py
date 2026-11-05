# Measure a symbol's ink in a 2x capture: coverage per pixel against the region's background.
import sys, numpy as np
from PIL import Image
def load(path): return np.asarray(Image.open(path).convert('RGB')).astype(float)
def coverage(img, x0, y0, x1, y1, bg=None, ink=None):
    r = img[y0:y1, x0:x1]
    if bg is None:
        edge = np.concatenate([r[0], r[-1], r[:,0], r[:,-1]])
        bg = np.median(edge, axis=0)
    d = np.abs(r - bg).sum(axis=2)
    if ink is None:
        iy, ix = np.unravel_index(np.argmax(d), d.shape); ink = r[iy, ix]
    full = np.abs(np.asarray(ink) - bg).sum()
    return np.clip(d / full, 0, 1), bg, ink
def report(name, img, x0, y0, x1, y1, cx, cy, show=True):
    c, bg, ink = coverage(img, x0, y0, x1, y1)
    m = c > 0.5
    ys, xs = np.nonzero(m)
    # box in points from (cx, cy) (px), each edge at the covered pixels' outer edge
    L = (x0 + xs.min() - cx) / 2; R = (x0 + xs.max() + 1 - cx) / 2
    T = (y0 + ys.min() - cy) / 2; B = (y0 + ys.max() + 1 - cy) / 2
    area = c.sum() / 4
    print(f'{name}: bg {bg.round(1)} ink {ink} box x {L:.2f}..{R:.2f} y {T:.2f}..{B:.2f} ({R-L:.2f} x {B-T:.2f}) area {area:.1f}')
    if show:
        for yy in range(ys.min()-1, ys.max()+2):
            print(f'{(y0+yy-cy)/2:6.1f} ' + ''.join(' .:-=+*#%@'[min(9,int(v*9.99))] for v in c[yy, xs.min()-1:xs.max()+2]))
    return c
if __name__ == '__main__':
    a = sys.argv
    img = load(a[1]); x0,y0,x1,y1,cx,cy = map(int, a[2:8])
    report(a[1].split('/')[-1], img, x0,y0,x1,y1,cx,cy, show=len(a) < 10)
