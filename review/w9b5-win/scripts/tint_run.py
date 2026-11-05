import numpy as np
from tint import solve
P = [(0.1, 0.1, 0.1)]; Wk = [(1, 0.6039216, 0.4235294), (0.9411765, 0.38431373, 0.60784316)]
rows = {'header row y 300-330': (300, 300, 440, 330), 'mid sidebar y 1200-1300': (100, 1200, 400, 1300), 'bar gap y 1600-1630': (330, 1600, 440, 1630), 'top y 60-80': (300, 60, 400, 80)}
cases = [('win two-spaces-personal', 'cap-base/two-spaces-personal.png', P, 0, 0.44, 32 / 255),
         ('mac w9c rest (Personal)', 'ref/review/w9c-mac/rest.png', P, 0, 0.44, None),
         ('mac w9d rest (Personal)', 'ref/review/w9d-mac/rest.png', P, 0, 0.44, None),
         ('mac w9b sidebar (Personal)', 'ref/review/w9b-mac/sidebar.png', P, 0, 0.44, None),
         ('win two-spaces (Work)', 'cap-base/two-spaces.png', Wk, 0.35, 0.55, 243 / 255),
         ('mac w9b two-spaces (Work)', 'ref/review/w9b-mac/two-spaces.png', Wk, 0.35, 0.55, None)]
for name, path, colors, grain, tint, base in cases:
    print(name, '(residual vs model)' if base is not None else '(material solved)')
    for label, box in rows.items():
        r = solve(path, colors, grain, tint, box, base).reshape(-1, 3)
        print(f'   {label}: mean {r.mean(0).round(2)} median {np.median(r, 0).round(2)} sd {r.std(0).round(2)}')
