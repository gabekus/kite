"""Summarizes osrperf runs (one JSON per run) as the markdown tables in docs/windows-osr-spike.md.

    py windows/tools/osrperf/summarize.py RUNS_DIR [TAG]

Runs are named TAG-<page>-<mode>-<n>.json; each number is the median over a cell's runs.
"""
import glob
import json
import os
import re
import statistics
import sys

runs_dir = sys.argv[1]
tag = sys.argv[2] if len(sys.argv) > 2 else 'm'
cells = {}
for path in sorted(glob.glob(os.path.join(runs_dir, f'{tag}-*.json'))):
    m = re.match(rf'{re.escape(tag)}-(.+)-(windowed|osr\w*)-(\d+)\.json$', os.path.basename(path))
    if not m:
        continue
    with open(path, encoding='utf-8') as f:
        cells.setdefault((m.group(1), m.group(2)), []).append(json.load(f))


def med(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def role_sum(run, role, field, part=None):
    procs = (part or run)['processes']
    return sum(p[field] for p in procs if p['role'] == role or (role == 'kite' and p['role'] != 'dwm'))


def fmt(v, digits=1):
    if v is None:
        return '-'
    return f'{v:.{digits}f}'


rows = []
for (page, mode), runs in sorted(cells.items()):
    lat = [r.get('latency') for r in runs]
    row = {
        'page': page, 'mode': mode, 'n': len(runs),
        'sys': med([r['systemCpuPercent'] for r in runs]),
        'fps': med([r['cadence']['fps'] for r in runs]),
        'p50': med([(r['cadence']['intervalMs'] or {}).get('p50') for r in runs]),
        'p99': med([(r['cadence']['intervalMs'] or {}).get('p99') for r in runs]),
        'kite': med([role_sum(r, 'browser', 'cpuMsPerS') for r in runs]),
        'gpuproc': med([role_sum(r, 'gpu-process', 'cpuMsPerS') for r in runs]),
        'renderer': med([role_sum(r, 'renderer', 'cpuMsPerS') for r in runs]),
        'total': med([role_sum(r, 'kite', 'cpuMsPerS') for r in runs]),
        # CPU per presented frame, where frames flow: the 500 Hz display sets the rate, this the cost.
        'perFrame': med([role_sum(r, 'kite', 'cpuMsPerS') / r['cadence']['fps'] for r in runs if r['cadence']['fps'] > 20]),
        'gpuKite': med([role_sum(r, 'browser', 'gpuEngineMsPerS') for r in runs]),
        'gpuGpu': med([role_sum(r, 'gpu-process', 'gpuEngineMsPerS') for r in runs]),
        'gpuDwm': med([role_sum(r, 'dwm', 'gpuEngineMsPerS') for r in runs]),
        'memKite': med([role_sum(r, 'browser', 'gpuDedicatedMB') for r in runs]),
        'memGpu': med([role_sum(r, 'gpu-process', 'gpuDedicatedMB') for r in runs]),
        'lat50': med([l['ms']['p50'] if l and l.get('ms') != 'null' and isinstance(l.get('ms'), dict) else None for l in lat]),
        'lat90': med([l['ms']['p90'] if l and isinstance(l.get('ms'), dict) else None for l in lat]),
        'misses': sum(l.get('misses', 0) for l in lat if l),
        'presents': med([r['osr']['presentsPerS'] for r in runs if 'osr' in r]),
        'copy': med([r['osr']['copyPresentMsMean'] for r in runs if 'osr' in r]),
        'minTotal': med([role_sum(r, 'kite', 'cpuMsPerS', r['minimized']) for r in runs if 'minimized' in r]),
        'minPresents': med([r['minimized']['osr']['presentsPerS'] for r in runs if 'minimized' in r and 'osr' in r['minimized']]),
    }
    rows.append(row)

print('| page | mode | runs | sys CPU % | frames/s (WGC) | interval p50 / p99 ms | Kite.exe CPU ms/s | GPU proc CPU ms/s | renderer CPU ms/s | all Kite CPU ms/s | all Kite CPU ms/frame |')
print('|---|---|---|---|---|---|---|---|---|---|---|')
for r in rows:
    print(f"| {r['page']} | {r['mode']} | {r['n']} | {fmt(r['sys'], 0)} | {fmt(r['fps'], 0)} | {fmt(r['p50'], 2)} / {fmt(r['p99'], 2)} | "
          f"{fmt(r['kite'])} | {fmt(r['gpuproc'])} | {fmt(r['renderer'])} | {fmt(r['total'])} | {fmt(r['perFrame'], 2)} |")
print()
print('| page | mode | GPU engine ms/s: Kite.exe / GPU proc / dwm | GPU dedicated MB: Kite.exe / GPU proc | input to frame p50 / p90 ms (misses) | --osr presents/s, copy+present ms |')
print('|---|---|---|---|---|---|')
for r in rows:
    osr = f"{fmt(r['presents'], 0)}, {fmt(r['copy'], 2)}" if r['presents'] is not None else '-'
    print(f"| {r['page']} | {r['mode']} | {fmt(r['gpuKite'])} / {fmt(r['gpuGpu'])} / {fmt(r['gpuDwm'])} | {fmt(r['memKite'], 0)} / {fmt(r['memGpu'], 0)} | "
          f"{fmt(r['lat50'], 1)} / {fmt(r['lat90'], 1)} ({r['misses']}) | {osr} |")
if any(r['minTotal'] is not None for r in rows):
    print()
    print('| page | mode | minimized: all Kite CPU ms/s | minimized: --osr presents/s |')
    print('|---|---|---|---|')
    for r in rows:
        if r['minTotal'] is not None:
            print(f"| {r['page']} | {r['mode']} | {fmt(r['minTotal'])} | {fmt(r['minPresents'], 1)} |")
