#!/usr/bin/env bash
# Plays the performance video in the simulator and measures the app while it plays with the controls
# hidden (how a film is watched): the CPU time it used over 45 seconds, its CPU share sampled once a
# second, and its memory. Usage: measure.sh <simulator id> <label> [extra launch arguments...]
set -uo pipefail
SIM=$1; LABEL=$2; shift 2
OUT=ios/.artifacts/perf
BUNDLE=com.amit29533.TwilDiary
mkdir -p "$OUT"
file=$(echo "$LABEL" | tr ' ' '-')
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
launch=$(xcrun simctl launch "$SIM" "$BUNDLE" --ui-testing --jellyspace-perf "http://127.0.0.1:8765/perf.mkv" "$@")
pid=${launch##*: }
echo "$LABEL: pid $pid"
# Opening the video, then the controls hide four seconds after it plays.
sleep 20
xcrun simctl io "$SIM" screenshot "$OUT/$file-start.png" >/dev/null 2>&1 || true
seconds() { ps -o time= -p "$1" | awk -F'[:.]' '{ n = NF; s = $(n-1) + $n / 100; if (n >= 3) s += $(n-2) * 60; if (n >= 4) s += $(n-3) * 3600; print s }'; }
before=$(seconds "$pid"); started=$(date +%s)
: > "$OUT/$file.samples"
for _ in $(seq 1 45); do
  ps -o %cpu=,rss= -p "$pid" >> "$OUT/$file.samples" || { echo "$LABEL: the app quit"; break; }
  sleep 1
done
after=$(seconds "$pid" || echo "$before"); ended=$(date +%s)
xcrun simctl io "$SIM" screenshot "$OUT/$file-end.png" >/dev/null 2>&1 || true
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
python3 - "$OUT/$file.samples" "$LABEL" "$before" "$after" "$started" "$ended" >> "$OUT/results.md" <<'PY'
import statistics, sys
path, label, before, after, started, ended = sys.argv[1:7]
rows = [line.split() for line in open(path) if line.strip()]
if len(rows) < 10:
    print(f"| {label} | the app quit after {len(rows)} s | | | |")
    raise SystemExit
cpu = [float(row[0]) for row in rows]
memory = max(int(row[1]) for row in rows) / 1024
used = float(after) - float(before); wall = max(1, int(ended) - int(started))
print(f"| {label} | {100 * used / wall:.1f}% | {statistics.median(cpu):.1f}% | {max(cpu):.1f}% | {memory:.0f} MB |")
PY
tail -1 "$OUT/results.md"
