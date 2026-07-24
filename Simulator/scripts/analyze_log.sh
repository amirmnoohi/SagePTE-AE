#!/usr/bin/env bash
# SagePTE artifact — parse the LAST "Page Walk Statistics" dump of a
# simulator log (the cumulative final stats), skipping the interim
# heartbeat dumps that make whole-log parsing slow on multi-GB logs.
#
# Usage: analyze_log.sh <sim log>          (prints analysis to stdout)
# e.g.:  analyze_log.sh Data/redis/sim_arm.log > Results/redis/analysis_arm.txt
set -euo pipefail

L="${1:?usage: analyze_log.sh <sim log>}"
S=$(dirname "$(realpath -e "${BASH_SOURCE[0]:-$0}")")

off=$(grep -ab "Page Walk Statistics:" "$L" | tail -1 | cut -d: -f1 || true)
if [ -z "$off" ]; then
    echo "Error: no \"Page Walk Statistics\" section in $L" >&2
    exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
tail -c +$((off + 1)) "$L" > "$tmp"
"$S/parse_walk_stats.py" "$tmp" | sed "s|$tmp|$L (final dump)|"
