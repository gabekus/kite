# Fit Kite's own briefcase (rounded-rect outlines, a curved band, a clasp) to the Mac's 2x coverage.
import numpy as np, json, sys
from measure import load, coverage
SS = 6
def rr_inside(x, y, l, t, r, b, rad):
    rad = max(0.0, min(rad, (r - l) / 2, (b - t) / 2))
    cx = np.clip(x, l + rad, r - rad); cy = np.clip(y, t + rad, b - rad)
    return (x >= l) & (x <= r) & (y >= t) & (y <= b) & ((x - cx) ** 2 + (y - cy) ** 2 <= rad * rad + 1e-9)
def shape(p, x, y):
    L, T, R, B, ro, s = p['L'], p['T'], p['R'], p['B'], p['ro'], p['s']
    body = rr_inside(x, y, L, T, R, B, ro) & ~rr_inside(x, y, L + s, T + s, R - s, B - s, ro - s)
    hl, hr, ht, hs = p['hl'], p['hr'], p['ht'], p['hs']
    handle = rr_inside(x, y, hl, ht, hr, T + 1, p['hr_']) & ~rr_inside(x, y, hl + hs, ht + hs, hr - hs, T + 1 + hs, max(p['hr_'] - hs, 0.1))
    handle &= y <= T + 0.5
    # band: between two parabolas across the inside, touching the walls
    xm = (L + R) / 2; hw = (R - L) / 2
    u = np.clip((x - xm) / hw, -1, 1)
    top = p['bs'] + (p['bm'] - p['bs']) * (1 - u * u)
    band = (y >= top) & (y <= top + p['bw']) & (x >= L) & (x <= R)
    clasp = rr_inside(x, y, p['cl'], p['bm'] , p['cr'], p['cb'], p['crad'])
    clasp_top = rr_inside(x, y, p['cl'], p['bm'] - 1, p['cr'], p['cb'] - 0.5, 0) & (y <= p['cb'])
    return body | handle | band | clasp | (clasp_top & (y >= p['bm']))
def render(p, x0pt, y0pt, w, h, scale=1.0, px=0.5):
    # pixel (i, j) covers [x0pt + i*px, +px) in output points; shape is in 12.5pt units * scale
    o = (np.arange(SS) + 0.5) / SS * px
    xs = (x0pt + np.arange(w)[:, None] * px + o[None, :]).ravel()
    ys = (y0pt + np.arange(h)[:, None] * px + o[None, :]).ravel()
    X, Y = np.meshgrid(xs / scale, ys / scale)
    m = shape(p, X, Y).astype(float)
    return m.reshape(h, SS, w, SS).mean(axis=(1, 3))
P0 = dict(L=-7.5, T=-3.5, R=7.2, B=6.5, ro=1.9, s=1.35, hl=-2.9, hr=3.5, ht=-5.95, hs=1.25, hr_=1.2,
          bs=-0.7, bm=0.1, bw=1.3, cl=-2.0, cr=1.6, cb=2.5, crad=0.5)
def mac_bar():
    img = load('ref/review/w9d-mac/rest.png'); x0, y0, x1, y1 = 206, 1560, 274, 1620
    c, _, _ = coverage(img, x0, y0, x1, y1)
    return c, (x0 - 240) / 2, (y0 - 1590) / 2
def mac_hdr():
    img = load('ref/review/w9b-mac/two-spaces.png'); x0, y0, x1, y1 = 24, 298, 80, 354
    c, _, _ = coverage(img, x0, y0, x1, y1)
    return c, (x0 - 52) / 2, (y0 - 326) / 2
def err(p, target):
    c, x0, y0 = target
    r = render(p, x0, y0, c.shape[1], c.shape[0])
    return ((r - c) ** 2).sum(), r
if __name__ == '__main__':
    target = mac_bar()
    p = dict(P0)
    if len(sys.argv) > 1: p.update(json.load(open(sys.argv[1])))
    e, _ = err(p, target)
    step = 0.2
    while step > 0.012:
        improved = True
        while improved:
            improved = False
            for k in p:
                for d in (step, -step):
                    q = dict(p); q[k] += d
                    e2, _ = err(q, target)
                    if e2 < e - 1e-6: p, e, improved = q, e2, True
        step /= 2
        print(f'step {step:.3f} err {e:.3f}', flush=True)
    print(json.dumps({k: round(v, 3) for k, v in p.items()}))
    json.dump(p, open('fit.json', 'w'))
