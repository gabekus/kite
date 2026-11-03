"""Compares the sidebar list's geometry in two `kite ui tree` dumps (SwiftUI before, AppKit after):
each title's text box, each favicon and each filled pill, matched by title and position.
Usage: python3 -I scripts/perf/treediff.py before/tree.txt after/tree.txt"""
import re, sys

FRAME = re.compile(r'\[(-?[\d.]+),(-?[\d.]+) (-?[\d.]+)×(-?[\d.]+)\]')

def parse(path):
    texts, icons, pills = {}, [], []
    for line in open(path):
        m = FRAME.search(line)
        if not m or 'hidden=true' in line:
            continue
        x, y, w, h = map(float, m.groups())
        if y < 157:  # above the list: header buttons, address field, favorites
            continue
        v = re.search(r'value="([^"]*)"', line) or re.search(r'SidebarLabel "([^"]*)"', line)
        if 'AXStaticText' in line and v:
            texts[(v.group(1), round(y))] = (x, y, w, h)
        elif 'SidebarLabel' in line and v:
            texts[(v.group(1), round(y))] = (x + 2, y, w - 4, h)  # the cell's 2pt inset each side
        elif ('AXImage' in line and '#globe' in line) or 'FaviconImageView' in line:
            icons.append((x, y, w, h))
        elif 'bg=#' in line and 'radius=11' in line:
            pills.append((x, y, w, h, line.split('bg=')[1].split()[0]))
    return texts, sorted(set(icons), key=lambda r: (r[1], r[0])), sorted(set(pills), key=lambda r: (r[1], r[0]))

a, b = parse(sys.argv[1]), parse(sys.argv[2])
worst = 0.0
print("titles (x, y, w, h) before -> after")
for key in sorted(set(a[0]) | set(b[0]), key=lambda k: k[1]):
    ra, rb = a[0].get(key), b[0].get(key)
    if ra and rb:
        d = max(abs(p - q) for p, q in zip(ra, rb))
        worst = max(worst, max(abs(ra[0] - rb[0]), abs(ra[1] - rb[1]), abs(ra[3] - rb[3])))
        print(f"  {key[0]!r:24} {ra} -> {rb}  max delta {d:g}")
    else:
        print(f"  {key[0]!r:24} only {'before' if ra else 'after'}: {ra or rb}")
for name, i in (("favicons", 1), ("pills", 2)):
    sa, sb = set(a[i]), set(b[i])
    print(f"{name}: {len(sa)} before, {len(sb)} after, {len(sa & sb)} identical")
    for r in sorted(sa - sb): print("   before only", r)
    for r in sorted(sb - sa): print("   after only ", r)
print(f"worst title origin/height delta: {worst:g} pt (widths differ by SwiftUI's fractional text width vs AppKit's rounded one)")
