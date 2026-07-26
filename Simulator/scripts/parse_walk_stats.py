#!/usr/bin/env python3
# SagePTE artifact — page walk statistics analyzer.
"""
Parse the "Page Walk Statistics" section of a simulator log (sim_arm.log /
sim_x86.log), compute the average nested-page-walk latency for every evaluated
design, project the end-to-end speedup each design implies, and compare all of
it against the values reported in the paper.

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

End-to-end speedup follows the paper's Eq. (4): a design that makes page walks
s times faster, in a workload that spends a fraction f of its time walking,
speeds the workload up by 1 / ((1 - f) + f / s). The fractions are measured on
real hardware and are properties of the workload, not of the simulation, so
they are taken from the paper.

Usage:
    parse_walk_stats.py [options] <sim_log> [<sim_log> ...]

Options:
    --workload NAME   workload to compare against (default: inferred from path)
    --config NAME     configuration label for the header (default: inferred)
    --no-compare      omit the paper columns; report measurements only
    --no-thp          omit the projected THP section
"""

import os
import re
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

# Presentation order. TPT is reported by the paper but computed by a separate
# tool, so it appears in the comparison columns with no measured counterpart.
DESIGN_ORDER = ['Nested paging (NPW)', 'SagePTE', 'DMT', 'ECPT', 'FPT',
                'ASAP', 'Agile Paging']
PAPER_ONLY = ['TPT']

# ------------------------------------------------------------------------------
# Reference values from the paper, generated from SagePTE-MICRO/numbers/.
#
#   frac_*     fraction of execution time spent on page walks (Page Walk Ratio)
#   hfinal_*   per-level share of walk latency spent in the h-final phase,
#              in percent of total walk latency (Last Level PTEs breakdown)
#   walk_*     page-walk speedup vs nested paging (Page Walk Latency)
#   e2e_*      end-to-end speedup (End to End)
# ------------------------------------------------------------------------------
PAPER = {
    'btree': {
        'frac_4k': 0.4447275661443071, 'frac_thp': 0.4014285714285717,
        'hfinal_4k': [0.9003, 1.2317, 8.1699, 34.4702],
        'hfinal_thp': [2.2231, 5.4602, 33.3233],
        'walk_4k': {"SagePTE": 1.8107, "DMT": 1.2968, "ECPT": 1.2821, "FPT": 1.2442, "ASAP": 1.1811, "Agile Paging": 1.2337, "TPT": 1.2605},
        'walk_thp': {"SagePTE": 1.6951, "DMT": 1.4264, "ECPT": 1.2716, "FPT": 1.1193, "ASAP": 1.0761, "Agile Paging": 1.2081, "TPT": 1.3593},
        'e2e_4k': {"SagePTE": 1.2486, "DMT": 1.1133, "ECPT": 1.1085, "FPT": 1.0956, "ASAP": 1.0732, "Agile Paging": 1.092, "TPT": 1.1012},
        'e2e_thp': {"SagePTE": 1.197, "DMT": 1.1364, "ECPT": 1.0938, "FPT": 1.0447, "ASAP": 1.0292, "Agile Paging": 1.0743, "TPT": 1.1187},
    },
    'canneal': {
        'frac_4k': 0.7815695864828817, 'frac_thp': 0.41477434277766256,
        'hfinal_4k': [0.938, 1.3019, 6.0492, 38.7476],
        'hfinal_thp': [2.3657, 4.9802, 35.0453],
        'walk_4k': {"SagePTE": 1.8881, "DMT": 1.1979, "ECPT": 1.1969, "FPT": 1.1363, "ASAP": 1.106, "Agile Paging": 1.1616, "TPT": 1.1162},
        'walk_thp': {"SagePTE": 1.7358, "DMT": 1.3685, "ECPT": 1.2909, "FPT": 0.9569, "ASAP": 1.056, "Agile Paging": 1.1703, "TPT": 1.3149},
        'e2e_4k': {"SagePTE": 1.5813, "DMT": 1.1483, "ECPT": 1.1475, "FPT": 1.1035, "ASAP": 1.081, "Agile Paging": 1.122, "TPT": 1.0885},
        'e2e_thp': {"SagePTE": 1.2133, "DMT": 1.1257, "ECPT": 1.1031, "FPT": 0.9817, "ASAP": 1.0225, "Agile Paging": 1.0642, "TPT": 1.1103},
    },
    'graph500': {
        'frac_4k': 0.20428433372704805, 'frac_thp': 0.07927987884844695,
        'hfinal_4k': [0.5679, 0.7639, 6.0993, 20.5378],
        'hfinal_thp': [1.1774, 4.5593, 15.4059],
        'walk_4k': {"SagePTE": 1.3883, "DMT": 2.1198, "ECPT": 1.7716, "FPT": 1.585, "ASAP": 1.3649, "Agile Paging": 1.585, "TPT": 1.8771},
        'walk_thp': {"SagePTE": 1.2681, "DMT": 2.9094, "ECPT": 1.5024, "FPT": 1.2707, "ASAP": 1.1216, "Agile Paging": 1.4729, "TPT": 2.6364},
        'e2e_4k': {"SagePTE": 1.0606, "DMT": 1.121, "ECPT": 1.0977, "FPT": 1.0815, "ASAP": 1.0578, "Agile Paging": 1.0815, "TPT": 1.1055},
        'e2e_thp': {"SagePTE": 1.017, "DMT": 1.0549, "ECPT": 1.0272, "FPT": 1.0172, "ASAP": 1.0087, "Agile Paging": 1.0261, "TPT": 1.0518},
    },
    'gups': {
        'frac_4k': 0.9628, 'frac_thp': 0.9447,
        'hfinal_4k': [0.9145, 1.1898, 7.7618, 34.3257],
        'hfinal_thp': [2.8984, 5.7667, 38.8988],
        'walk_4k': {"SagePTE": 1.7919, "DMT": 1.3087, "ECPT": 1.3036, "FPT": 1.2806, "ASAP": 1.1531, "Agile Paging": 1.2628, "TPT": 1.3252},
        'walk_thp': {"SagePTE": 1.9071, "DMT": 1.226, "ECPT": 1.2169, "FPT": 1.0753, "ASAP": 1.0731, "Agile Paging": 1.121, "TPT": 1.2119},
        'e2e_4k': {"SagePTE": 1.7406, "DMT": 1.2938, "ECPT": 1.289, "FPT": 1.2674, "ASAP": 1.1465, "Agile Paging": 1.2505, "TPT": 1.3094},
        'e2e_thp': {"SagePTE": 1.816, "DMT": 1.2109, "ECPT": 1.2025, "FPT": 1.0709, "ASAP": 1.0687, "Agile Paging": 1.1136, "TPT": 1.1886},
    },
    'memcached': {
        'frac_4k': 0.13883162668596255, 'frac_thp': 0.12693070655496,
        'hfinal_4k': [0.8729, 1.1526, 9.5648, 30.9449],
        'hfinal_thp': [2.2384, 5.302, 33.6142],
        'walk_4k': {"SagePTE": 1.7402, "DMT": 1.3995, "ECPT": 1.3766, "FPT": 1.3206, "ASAP": 1.2112, "Agile Paging": 1.3257, "TPT": 1.2343},
        'walk_thp': {"SagePTE": 1.6994, "DMT": 1.4178, "ECPT": 1.2925, "FPT": 1.1058, "ASAP": 1.1337, "Agile Paging": 1.2396, "TPT": 1.3544},
        'e2e_4k': {"SagePTE": 1.0628, "DMT": 1.0413, "ECPT": 1.0395, "FPT": 1.0349, "ASAP": 1.0248, "Agile Paging": 1.0353, "TPT": 1.0271},
        'e2e_thp': {"SagePTE": 1.0551, "DMT": 1.0389, "ECPT": 1.0296, "FPT": 1.0123, "ASAP": 1.0152, "Agile Paging": 1.0251, "TPT": 1.0344},
    },
    'redis': {
        'frac_4k': 0.47845267237862116, 'frac_thp': 0.44707524157988565,
        'hfinal_4k': [1.0142, 1.4075, 7.4093, 32.9118],
        'hfinal_thp': [4.7148, 6.0337, 35.0324],
        'walk_4k': {"SagePTE": 1.7305, "DMT": 1.3592, "ECPT": 1.3487, "FPT": 1.313, "ASAP": 1.2017, "Agile Paging": 1.3004, "TPT": 1.2245},
        'walk_thp': {"SagePTE": 1.8444, "DMT": 1.3141, "ECPT": 1.2725, "FPT": 1.0947, "ASAP": 1.1386, "Agile Paging": 1.1617, "TPT": 1.2176},
        'e2e_4k': {"SagePTE": 1.2531, "DMT": 1.1448, "ECPT": 1.1412, "FPT": 1.1287, "ASAP": 1.0873, "Agile Paging": 1.1243, "TPT": 1.0962},
        'e2e_thp': {"SagePTE": 1.2573, "DMT": 1.1196, "ECPT": 1.1059, "FPT": 1.0402, "ASAP": 1.0575, "Agile Paging": 1.0663, "TPT": 1.0868},
    },
    'xsbench': {
        'frac_4k': 0.6144562334217507, 'frac_thp': 0.25554253284806605,
        'hfinal_4k': [0.8936, 1.2019, 6.8299, 35.0806],
        'hfinal_thp': [1.6227, 5.0707, 28.4832],
        'walk_4k': {"SagePTE": 1.7859, "DMT": 1.2989, "ECPT": 1.2897, "FPT": 1.223, "ASAP": 1.1655, "Agile Paging": 1.2184, "TPT": 1.193},
        'walk_thp': {"SagePTE": 1.5427, "DMT": 1.6656, "ECPT": 1.4303, "FPT": 1.1424, "ASAP": 1.0898, "Agile Paging": 1.2601, "TPT": 1.5846},
        'e2e_4k': {"SagePTE": 1.3706, "DMT": 1.1647, "ECPT": 1.1601, "FPT": 1.1262, "ASAP": 1.0956, "Agile Paging": 1.1238, "TPT": 1.1104},
        'e2e_thp': {"SagePTE": 1.0988, "DMT": 1.1137, "ECPT": 1.0833, "FPT": 1.0329, "ASAP": 1.0215, "Agile Paging": 1.0557, "TPT": 1.1041},
    },
}


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


def end_to_end(walk_speedup, walk_fraction):
    """Eq. (4): the whole-workload speedup a page-walk speedup buys.

    A design that makes walks s times faster only helps the fraction f of
    execution that was spent walking, so the workload finishes in
    (1 - f) + f/s of the time it used to take.
    """
    if walk_speedup <= 0:
        return float('nan')
    return 1.0 / ((1.0 - walk_fraction) + walk_fraction / walk_speedup)


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


def tally(records, g_levels, h_levels, project=None):
    """Weighted averages for one walk shape.

    Returns (total_walks, {label: avg cycles}, {design: avg cycles}).
    `project` optionally rewrites each record's reference list, which is how a
    2 MB walk is derived from a 4 KB capture.
    """
    labels = labels_for(g_levels, h_levels)
    designs = formulas_for(g_levels, h_levels)
    total = 0
    ref_sum = [0.0] * len(labels)
    design_sum = {name: 0.0 for name in designs}

    for refs, _, count in records:
        toks = project(refs) if project else refs
        lat = [LATENCY[t] for t in toks]
        for i, v in enumerate(lat):
            ref_sum[i] += v * count
        d = dict(zip(labels, lat))
        for name, fn in designs.items():
            design_sum[name] += fn(d) * count
        total += count

    by_label = {l: s / total for l, s in zip(labels, ref_sum)}
    by_design = {n: s / total for n, s in design_sum.items()}
    return total, by_label, by_design


def project_4k_to_thp(refs):
    """Derive a 15-reference 2 MB walk from a 24-reference 4 KB one.

    A 2 MB mapping ends at the guest and host L3 entries, so the projection
    keeps guest levels 1-3, host levels 1-3 of each, and the first three
    h-final references, dropping everything indexed by a fourth level.

    This is an estimate, not a measurement. It reuses the cache and
    page-walk-cache behaviour observed with 4 KB mappings, whereas real huge
    pages shrink the page table by three orders of magnitude and hit in those
    structures far more often. Designs whose cost is dominated by the deep
    levels (SagePTE, DMT) survive the approximation well; designs carrying a
    fixed additive cost (ECPT) or reading every guest level (Agile Paging) do
    not. Simulate a capture taken with huge pages enabled for a real number.
    """
    src = labels_for(4, 4)
    d = dict(zip(src, refs))
    return [d[l] for l in labels_for(3, 3)]


# ------------------------------------------------------------------------------
# Reporting
# ------------------------------------------------------------------------------

def pct_delta(measured, reference):
    """Relative difference, as a signed percentage."""
    if not reference:
        return None
    return (measured / reference - 1.0) * 100.0


def fmt_delta(value, unit='%'):
    return '--' if value is None else f'{value:+.1f}{unit}'


def infer_workload(path):
    """Results/<workload>/sim_arm.log, Data/<workload>/..., or sim_<w>.log."""
    parts = os.path.abspath(path).split(os.sep)
    for part in reversed(parts[:-1]):
        if part.lower() in PAPER:
            return part.lower()
    stem = re.sub(r'^sim_|\.log$|\.dump$', '', os.path.basename(path))
    return stem.lower() if stem.lower() in PAPER else None


def infer_config(path):
    m = re.search(r'sim_(\w+?)\.log', os.path.basename(path))
    return m.group(1) if m else None


def print_header(path, workload, config, page, total, range_hits):
    print('=' * 78)
    print(' SagePTE — page-walk analysis')
    print('=' * 78)
    print(f'  workload      {workload or "unknown"}')
    print(f'  configuration {config or "unknown"}')
    print(f'  page size     {page}')
    print(f'  source        {path}')
    print(f'  page walks    {total:,} post-warmup')
    print(f'  DMT range     {range_hits / total * 100:.2f}% of walks covered')
    print()


def print_references(by_label, g_levels, h_levels):
    print('PER-REFERENCE LATENCY (cycles)')
    for g in range(1, g_levels + 1):
        row = [f'G{g}H{h}' for h in range(1, h_levels + 1)] + [f'G{g}']
        print('  ' + '  '.join(f'{l}={by_label[l]:7.2f}' for l in row))
    print('  ' + '  '.join(f'UDH{h}={by_label[f"UDH{h}"]:7.2f}'
                           for h in range(1, h_levels + 1)))
    print()


def print_hfinal(by_label, npw, h_levels, paper_shares):
    print('H-FINAL PHASE  (the terminal Stage-2 walk SagePTE eliminates)')
    total = sum(by_label[f'UDH{h}'] for h in range(1, h_levels + 1))
    compare = paper_shares and len(paper_shares) == h_levels
    head = f'  {"":<10}{"cycles":>10}{"share":>10}'
    if compare:
        head += f'{"paper":>10}{"delta":>12}'
    print(head)
    for h in range(1, h_levels + 1):
        share = by_label[f'UDH{h}'] / npw * 100
        line = f'  {"UDH" + str(h):<10}{by_label[f"UDH{h}"]:>10.2f}{share:>9.2f}%'
        if compare:
            ref = paper_shares[h - 1]
            line += f'{ref:>9.2f}%{share - ref:>+11.2f}pp'
        print(line)
    share = total / npw * 100
    line = f'  {"total":<10}{total:>10.2f}{share:>9.2f}%'
    if compare:
        ref = sum(paper_shares)
        line += f'{ref:>9.2f}%{share - ref:>+11.2f}pp'
    print(line)
    print()


def print_walk_table(title, by_design, paper_walk, note=None):
    print(title)
    if note:
        print(f'  {note}')
    npw = by_design['Nested paging (NPW)']
    compare = bool(paper_walk)
    head = f'  {"Design":<22}{"cycles":>10}{"speedup":>10}'
    if compare:
        head += f'{"paper":>10}{"delta":>10}'
    print(head)
    for name in DESIGN_ORDER:
        if name not in by_design:
            continue
        lat = by_design[name]
        speedup = npw / lat if lat > 0 else float('inf')
        line = f'  {name:<22}{lat:>10.2f}{speedup:>9.2f}x'
        if compare:
            ref = paper_walk.get('Nested paging (NPW)' if name.startswith('Nested')
                                 else name)
            if name.startswith('Nested'):
                ref = 1.0
            line += (f'{ref:>9.2f}x{fmt_delta(pct_delta(speedup, ref)):>10}'
                     if ref else f'{"--":>10}{"--":>10}')
        print(line)
    if compare:
        for name in PAPER_ONLY:
            ref = paper_walk.get(name)
            if ref:
                print(f'  {name:<22}{"--":>10}{"--":>10}{ref:>9.2f}x'
                      f'{"not simulated":>16}')
    print()


def print_e2e_table(title, by_design, fraction, paper_e2e, note=None):
    print(title)
    if note:
        print(f'  {note}')
    print(f'  page-walk fraction of execution time  f = {fraction * 100:.2f}%')
    npw = by_design['Nested paging (NPW)']
    compare = bool(paper_e2e)
    head = f'  {"Design":<22}{"walk":>10}{"end-to-end":>12}'
    if compare:
        head += f'{"paper":>10}{"delta":>10}'
    print(head)
    for name in DESIGN_ORDER:
        if name not in by_design or name.startswith('Nested'):
            continue
        speedup = npw / by_design[name]
        e2e = end_to_end(speedup, fraction)
        line = f'  {name:<22}{speedup:>9.2f}x{e2e:>11.3f}x'
        if compare:
            ref = paper_e2e.get(name)
            line += (f'{ref:>9.3f}x{fmt_delta(pct_delta(e2e, ref)):>10}'
                     if ref else f'{"--":>10}{"--":>10}')
        print(line)
    print()


def analyze(path, workload=None, config=None, compare=True, thp=True):
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
    is_4k = n_refs == 24
    workload = workload or infer_workload(path)
    config = config or infer_config(path)
    ref = PAPER.get(workload) if compare else None

    total, by_label, by_design = tally(records, g_levels, h_levels)
    range_hits = sum(c for _, flag, c in records if flag == 'RANGE_HIT')
    npw = by_design['Nested paging (NPW)']

    print_header(path, workload, config, '4 KB' if is_4k else '2 MB (THP)',
                 total, range_hits)
    print_references(by_label, g_levels, h_levels)
    print_hfinal(by_label, npw, h_levels,
                 ref.get('hfinal_4k' if is_4k else 'hfinal_thp') if ref else None)

    tag = '4k' if is_4k else 'thp'
    print_walk_table(f'PAGE-WALK LATENCY  ({"4 KB" if is_4k else "2 MB"} pages)',
                     by_design, ref.get(f'walk_{tag}') if ref else None)

    if ref and ref.get(f'frac_{tag}'):
        print_e2e_table('END-TO-END SPEEDUP  (Eq. 4)', by_design,
                        ref[f'frac_{tag}'], ref.get(f'e2e_{tag}'))

    # Projected huge-page results, when the capture used 4 KB pages.
    if thp and is_4k:
        _, thp_labels, thp_design = tally(records, 3, 3, project=project_4k_to_thp)
        note = ('estimated from this 4 KB capture by dropping the fourth guest '
                'and host level;\n  it reuses 4 KB cache behaviour, so treat it '
                'as indicative — capture with\n  huge pages enabled for a '
                'measured result')
        print_walk_table('PAGE-WALK LATENCY  (2 MB pages, PROJECTED)',
                         thp_design, ref.get('walk_thp') if ref else None,
                         note=note)
        if ref and ref.get('frac_thp'):
            print_e2e_table('END-TO-END SPEEDUP  (2 MB pages, PROJECTED)',
                            thp_design, ref['frac_thp'], ref.get('e2e_thp'))

    if compare and not ref:
        print(f'  (no paper reference for workload "{workload}"; '
              f'known: {", ".join(sorted(PAPER))})')
        print()


def main():
    args = sys.argv[1:]
    workload = config = None
    compare = thp = True
    paths = []
    while args:
        a = args.pop(0)
        if a == '--workload':
            workload = args.pop(0).lower()
        elif a == '--config':
            config = args.pop(0)
        elif a == '--no-compare':
            compare = False
        elif a == '--no-thp':
            thp = False
        elif a in ('-h', '--help'):
            print(__doc__)
            return
        else:
            paths.append(a)
    if not paths:
        print(__doc__)
        sys.exit(1)
    for path in paths:
        analyze(path, workload, config, compare, thp)


if __name__ == '__main__':
    main()
