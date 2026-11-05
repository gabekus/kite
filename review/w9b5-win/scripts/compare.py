# Briefcase: Windows' captures against the Mac's, same fixture, same window points, 2x.
import numpy as np
from measure import load, coverage
R = 'ref/review/'
cases = [
    ('bar greyed, dark (three-spaces)', R + 'w9d-mac/rest.png', 'three-spaces.png', (240, 1590), 30),
    ('bar greyed, dark (two-spaces Personal)', R + 'w9c-mac/rest.png', 'two-spaces-personal.png', (274, 1590), 30),
    ('bar greyed, dark (sidebar)', R + 'w9b-mac/sidebar.png', 'sidebar.png', (274, 1590), 30),
    ('bar lit, light (two-spaces Work)', R + 'w9b-mac/two-spaces.png', 'two-spaces.png', (274, 1590), 30),
    ('header lit, 15pt (two-spaces Work)', R + 'w9b-mac/two-spaces.png', 'two-spaces.png', (52, 326), 28),
]
def box(c, x0, y0, cx, cy):
    ys, xs = np.nonzero(c > 0.5)
    return ((x0 + xs.min() - cx) / 2, (x0 + xs.max() + 1 - cx) / 2, (y0 + ys.min() - cy) / 2, (y0 + ys.max() + 1 - cy) / 2)
def fmt(b): return f'x {b[0]:+.2f}..{b[1]:+.2f} y {b[2]:+.2f}..{b[3]:+.2f} ({b[1]-b[0]:.2f}x{b[3]-b[2]:.2f}) centre ({(b[0]+b[1])/2:+.2f},{(b[2]+b[3])/2:+.2f})'
for name, mac, win, (cx, cy), h in cases:
    x0, y0, x1, y1 = cx - h, cy - h, cx + h, cy + h
    m, mbg, mink = coverage(load(mac), x0, y0, x1, y1)
    print(name)
    print(f'  mac      {fmt(box(m, x0, y0, cx, cy))} ink {mink} on {mbg}')
    for tag in ('cap-base', 'cap-new'):
        w, wbg, wink = coverage(load(f'{tag}/{win}'), x0, y0, x1, y1)
        mism = int(((m > .5) != (w > .5)).sum()); n = int((m > .5).sum())
        print(f'  {tag:8} {fmt(box(w, x0, y0, cx, cy))} ink {wink} on {wbg}; px differing (>half covered) {mism} of {n}, mean |coverage diff| {np.abs(m - w).mean():.3f}')
