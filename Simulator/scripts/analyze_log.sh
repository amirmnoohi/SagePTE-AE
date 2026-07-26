#!/usr/bin/env bash
# SagePTE artifact — parse the LAST "Page Walk Statistics" dump of a
# simulator log (the cumulative final stats), skipping the interim
# heartbeat dumps that make whole-log parsing slow on multi-GB logs.
#
# Usage: analyze_log.sh <sim log> [parse_walk_stats.py options]
# e.g.:  analyze_log.sh Results/redis/sim_arm.log > Results/redis/analysis_arm.txt
#        analyze_log.sh Results/redis/sim_arm.log --no-thp
set -euo pipefail

L="${1:?usage: analyze_log.sh <sim log> [options]}"
shift || true
S=$(dirname "$(realpath -e "${BASH_SOURCE[0]:-$0}")")

off=$(grep -ab "Page Walk Statistics:" "$L" | tail -1 | cut -d: -f1 || true)
if [ -z "$off" ]; then
    echo "Error: no \"Page Walk Statistics\" section in $L" >&2
    exit 1
fi

# The analyzer compares against the paper per workload, and labels the report
# with the configuration; it normally reads both off the log's path. Below it
# is handed a temporary file instead, so they are resolved here, from
# Results/<workload>/sim_<config>.log.
workload=$(basename "$(dirname "$(realpath -e "$L")")")
config=$(basename "$L" .log); config="${config#sim_}"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
tail -c +$((off + 1)) "$L" > "$tmp"
"$S/parse_walk_stats.py" --workload "$workload" --config "$config" "$@" "$tmp" |
    sed "s|$tmp|$L (final dump)|"
