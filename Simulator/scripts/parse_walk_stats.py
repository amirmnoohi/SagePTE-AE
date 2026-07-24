#!/usr/bin/env python3
# SagePTE artifact — page walk statistics analyzer.
"""
Parse the "Page Walk Statistics" section of a simulator log (sim_arm.log /
sim_x86.log) and compute the average nested-page-walk latency for every
evaluated design.

Each histogram line records one unique page-walk pattern and its frequency:

    <ref_1>,<ref_2>,...,<ref_N>,<RANGE_HIT|RANGE_MISS>,\t<count>

where <ref_i> names the memory-hierarchy component that served the i-th
page-walk reference (MEMORY, L1, L2, LLC, PWC, or ZERO if the reference was
skipped because of a page-walk-cache hit) and the trailing flag reports
range-table coverage (informational).

Reference order for 4 KB pages (24 refs):
    G1H1 G1H2 G1H3 G1H4 G1   (host walk for the guest L1 table GPA + L1 PTE)
    G2H1 G2H2 G2H3 G2H4 G2
    G3H1 G3H2 G3H3 G3H4 G3
    G4H1 G4H2 G4H3 G4H4 G4   (G4 = guest leaf PTE read)
    UDH1 UDH2 UDH3 UDH4      (final host walk for the data GPA: the h-final
                              phase that SagePTE eliminates)

For 2 MB pages (THP in guest and host) the walk has 15 refs:
    3 guest levels x (3 host refs + 1 guest ref) + 3 h-final refs.

Per-design walk-latency formulas are ported from the paper's processor tool
(dmt/processor/Formula.cs, "Virt4K"/"Virt2M" groups; DMT appears there under
its internal name "Hyperlane"). Formulas are evaluated PER PATTERN and
averaged weighted by frequency, exactly like Formula.cs's PullAverage —
required because ASAP's prefetcher model uses max() and is nonlinear.

Usage: parse_walk_stats.py <sim_log> [<sim_log> ...]
"""

import sys

# Cycle cost of a page-walk reference served by each component (Constants).
LATENCY = {
    'PWC': 1,
    'L1': 4,
    'L2': 14,
    'LLC': 54,
    'MEMORY': 200,
    'ZERO': 0,
    'WRONG': 0,
}

# Design constants from Formula.cs.
ECPT_VIRT = 4 + 4 + 4   # cuckoo-hash probe cost under virt. (see NECPT fig 6)
ASAP_G3EST = 0          # ASAP prefetch-issue estimates: assume the best
ASAP_G4EST = 0

# Trailing range-table coverage flag (optional in older logs).
RANGE_FLAGS = {'RANGE_HIT', 'RANGE_MISS'}

TOKENS = set(LATENCY) | RANGE_FLAGS

# walk length -> (guest levels, host levels)
WALK_SHAPES = {24: (4, 4), 15: (3, 3)}


def labels_for(g_levels, h_levels):
    out = []
    for g in range(1, g_levels + 1):
        out += [f'G{g}H{h}' for h in range(1, h_levels + 1)] + [f'G{g}']
    out += [f'UDH{h}' for h in range(1, h_levels + 1)]
    return out


def asap_prefetch(*stages):
    """ASAP_Prefetcher from Formula.cs: level i can start once levels 1..2 are
    summed; deeper levels overlap via prefetching (est = issue delay)."""
    done = stages[0] + stages[1]
    for i, s in enumerate(stages[2:]):
        est = ASAP_G3EST if i == 0 else ASAP_G4EST
        done = max(done + est, s)
    return done


def formulas_for(g_levels, h_levels):
    """Return {design: fn(d)} where d maps position label -> ref latency.
    Direct port of Formula.cs Virt4K (g=h=4) / Virt2M (g=h=3)."""
    ALL = labels_for(g_levels, h_levels)
    G = [f'G{i}' for i in range(1, g_levels + 1)]
    GH = {i: [f'G{i}H{j}' for j in range(1, h_levels + 1)]
          for i in range(1, g_levels + 1)}
    UD = [f'UDH{j}' for j in range(1, h_levels + 1)]
    g_last, h_last = g_levels, h_levels
    # FPT flattens pairs of levels: it touches guest groups (and host refs)
    # of the same parity as the last level — 2,4 for 4KB walks; 1,3 for THP.
    fpt_g = [i for i in range(1, g_levels + 1) if i % 2 == g_last % 2]
    fpt_h = [j for j in range(1, h_levels + 1) if j % 2 == h_last % 2]

    def npw(d):
        return sum(d[k] for k in ALL)

    def sagepte(d):
        # hePTE co-located with the guest leaf: the h-final refs vanish.
        return npw(d) - sum(d[k] for k in UD)

    def dmt(d):
        return d[GH[g_last][-1]] + d[G[-1]] + d[UD[-1]]

    def ecpt(d):
        return d[GH[g_last][-1]] + d[G[-1]] + d[UD[-1]] + ECPT_VIRT

    def fpt(d):
        return (sum(d[GH[i][j - 1]] for i in fpt_g for j in fpt_h) +
                sum(d[G[i - 1]] for i in fpt_g) +
                sum(d[f'UDH{j}'] for j in fpt_h))

    def asap(d):
        actual = [asap_prefetch(*(d[k] for k in GH[i])) + d[G[i - 1]]
                  for i in range(1, g_levels + 1)]
        return (asap_prefetch(*actual) +
                asap_prefetch(*(d[k] for k in UD)))

    def agile(d):
        # Shadow mode for the guest dimension + one final host walk.
        return sum(d[k] for k in G) + sum(d[k] for k in UD)

    # TPT is not part of Formula.cs (it was computed by a separate tool);
    # add its delegate here when its formula is available.
    return {
        'Nested paging (NPW)': npw,
        'SagePTE': sagepte,
        'DMT': dmt,
        'ECPT': ecpt,
        'FPT': fpt,
        'ASAP': asap,
        'Agile Paging': agile,
    }


def parse_log(path):
    """Return list of (refs, range_flag, count) walk records."""
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if '\t' not in line or ',' not in line:
                continue
            pattern_str, _, count_str = line.rpartition('\t')
            tokens = [t for t in pattern_str.split(',') if t]
            if not tokens or any(t not in TOKENS for t in tokens):
                continue
            flag = None
            if tokens[-1] in RANGE_FLAGS:
                flag = tokens[-1]
                tokens = tokens[:-1]
            try:
                count = int(count_str)
            except ValueError:
                continue
            records.append((tokens, flag, count))
    return records


def analyze(path):
    records = parse_log(path)
    if not records:
        print(f'{path}: no "Page Walk Statistics" records found')
        return

    n_refs = len(records[0][0])
    if any(len(r[0]) != n_refs for r in records):
        print(f'{path}: warning: mixed walk lengths, using {n_refs}-ref records only')
        records = [r for r in records if len(r[0]) == n_refs]
    if n_refs not in WALK_SHAPES:
        print(f'{path}: unsupported walk length {n_refs} (expected 24 for 4KB or 15 for 2MB)')
        return

    g_levels, h_levels = WALK_SHAPES[n_refs]
    labels = labels_for(g_levels, h_levels)
    designs = formulas_for(g_levels, h_levels)

    total = sum(c for _, _, c in records)
    range_hits = sum(c for _, flag, c in records if flag == 'RANGE_HIT')

    # Per-position averages (for the reference table + h-final share).
    avg = [0.0] * n_refs
    # Per-design averages, evaluated per pattern and weighted by frequency.
    design_sum = {name: 0.0 for name in designs}
    for refs, _, count in records:
        lat = [LATENCY[tok] for tok in refs]
        for i, v in enumerate(lat):
            avg[i] += v * count
        d = dict(zip(labels, lat))
        for name, fn in designs.items():
            design_sum[name] += fn(d) * count
    avg = [a / total for a in avg]
    by_label = dict(zip(labels, avg))
    design_avg = {name: s / total for name, s in design_sum.items()}

    h_final = [f'UDH{h}' for h in range(1, h_levels + 1)]
    npw = design_avg['Nested paging (NPW)']
    hfinal_lat = sum(by_label[l] for l in h_final)

    page = '4KB' if n_refs == 24 else '2MB/THP'
    print(f'=== {path} ({page} walks) ===')
    print(f'Total page walks (post-warmup): {total}')
    print(f'DMT range hit rate:             {range_hits / total * 100:.2f}%')
    print()
    print('Average latency per reference (cycles):')
    for g in range(1, g_levels + 1):
        row = [f'G{g}H{h}' for h in range(1, h_levels + 1)] + [f'G{g}']
        print('  ' + '  '.join(f'{l}={by_label[l]:7.2f}' for l in row))
    print('  ' + '  '.join(f'{l}={by_label[l]:7.2f}' for l in h_final))
    print()
    print(f'h-final phase: {hfinal_lat:.2f} cycles = {hfinal_lat / npw * 100:.1f}% of walk latency')
    print()
    print(f'{"Design":<22}{"Avg walk (cycles)":>18}{"Speedup vs NPW":>16}')
    for name, lat in design_avg.items():
        speedup = npw / lat if lat > 0 else float("inf")
        print(f'{name:<22}{lat:>18.2f}{speedup:>15.2f}x')
    print()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    for path in sys.argv[1:]:
        analyze(path)


if __name__ == '__main__':
    main()
