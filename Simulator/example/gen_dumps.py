#!/usr/bin/env python3
# SagePTE artifact
"""Generate synthetic guest/host page table dumps covering smoke.c's VA range.

Guest dump line:  VA,PE1,PE2,PE3,PE4,PA        (VA page-aligned full address;
                                                PE*/PA are PFNs, hex, no 0x)
Host dump line:   GPA,PE1,PE2,PE3,PE4,PA       (GPA page-aligned full address)

The host dump must cover the data GPAs *and* the GPAs of the guest page-table
pages themselves (PE1..PE4), since the nested walk translates those too.
"""
import sys

BASE = 0x100000000
PAGES = 16 * 1024 * 1024 // 4096  # 4096 pages

G_PE1 = 0x1000
G_PE2 = 0x1001
G_PE3 = 0x1003
G_PE4_BASE = 0x1100          # one L3 table per 512 pages
G_DATA_BASE = 0x40000        # guest data PFNs

H_PE1 = 0x2000
H_PE2 = 0x2001
H_PE3 = 0x2003
H_PE4_BASE = 0x2100
H_DATA_BASE = 0x80000        # host data PFNs

outdir = sys.argv[1] if len(sys.argv) > 1 else '.'

guest_lines = []
gpa_pfns = set()
for i in range(PAGES):
    va = BASE + i * 4096
    pe4 = G_PE4_BASE + i // 512
    data = G_DATA_BASE + i
    guest_lines.append(f"{va:x},{G_PE1:x},{G_PE2:x},{G_PE3:x},{pe4:x},{data:x}")
    gpa_pfns.add(data)
    gpa_pfns.update((G_PE1, G_PE2, G_PE3, pe4))

host_lines = []
for n, pfn in enumerate(sorted(gpa_pfns)):
    gpa = pfn << 12
    pe4 = H_PE4_BASE + pfn // 512
    host_lines.append(
        f"{gpa:x},{H_PE1:x},{H_PE2:x},{H_PE3:x},{pe4:x},{H_DATA_BASE + n:x}")

with open(f"{outdir}/pt_dump", "w") as f:
    f.write(f"{len(guest_lines)}\n")
    f.write("\n".join(guest_lines) + "\n")

with open(f"{outdir}/pt_dump.host", "w") as f:
    f.write(f"{len(host_lines)}\n")
    f.write("\n".join(host_lines) + "\n")

print(f"wrote {len(guest_lines)} guest entries, {len(host_lines)} host entries")
