# Medians over processes (and over the chosen repetitions) per snapshot, scenario, phase.
import sys, statistics as st, collections as cl
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1]) if l.startswith('ROW')]
snaps = sys.argv[2].split(',') if len(sys.argv) > 2 else ['main', 'inference-fix', 'route-fix']
data = cl.defaultdict(list)  # (snap, scen, reps-group, phase) -> [(compile, wall)]
for _, snap, proc, scen, rep, phase, c, w in rows:
    rep = int(rep)
    grp = 'cold' if scen == 'cold' else (scen + (' (1st re-run)' if rep == 1 else ' (re-runs 2-5)'))
    data[(snap, grp, phase)].append((float(c), float(w)))
groups = ['cold', 'warm, same uuids (1st re-run)', 'warm, same uuids (re-runs 2-5)',
          'same shape, new uuids (1st re-run)', 'same shape, new uuids (re-runs 2-5)']
phases = sorted({r[5] for r in rows})
def med(snap, grp, ph, k):
    v = data.get((snap, grp, ph)); return st.median(x[k] for x in v) if v else None
def f(x): return '—' if x is None else f'{x:,.1f}'
for k, what in ((0, 'compile time'), (1, 'wall time')):
    for g in groups:
        print(f'\n### {g}: {what} (µs, median)\n')
        print('| Phase | ' + ' | '.join(f'{x} (µs)' for x in snaps) + f' | {snaps[-1]} vs {snaps[0]} (×) |')
        print('|---|---|---|---|---|')
        tot = [0] * len(snaps)
        for ph in phases:
            vals = [med(s, g, ph, k) for s in snaps]
            if all(v is None for v in vals): continue
            for i, v in enumerate(vals): tot[i] += v or 0
            ratio = '—' if not vals[0] or vals[-1] is None else f'{vals[-1]/vals[0]:.3f} ×'
            print(f'| {ph} | ' + ' | '.join(f(v) for v in vals) + f' | {ratio} |')
        ratio = f'{tot[-1]/tot[0]:.3f} ×' if tot[0] else '—'
        print('| **total** | ' + ' | '.join(f'**{v:,.1f}**' for v in tot) + f' | {ratio} |')
