#!/usr/bin/env bash
# Plays the performance video in the simulator and measures the app while it plays with the controls
# hidden (how a film is watched), over 45 seconds:
#   CPU: the CPU time it used, and its share sampled once a second;
#   GPU: its own GPU time (powermetrics, per process) and how busy the Mac's GPU was;
#   energy: macOS's energy impact for the process (the number Activity Monitor shows);
#   memory: its peak resident memory;
#   disk: what it wrote (logical writes, what iOS's disk-writes report counts).
# The Simulator draws on the Mac's GPU and decodes in software, so the numbers are higher than a
# phone's: what counts is the difference between builds and settings.
# Usage: measure.sh <simulator id> <label> [extra launch arguments...]
# PERF_VIDEO picks the served file (perf.mkv, 1080p, unless set: perf720.mkv for the upscalers).
set -uo pipefail
SIM=$1; LABEL=$2; shift 2
OUT=ios/.artifacts/perf
BUNDLE=com.amit29533.TwilDiary
mkdir -p "$OUT"
file=$(echo "$LABEL" | tr ' ' '-')
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
launch=$(xcrun simctl launch "$SIM" "$BUNDLE" --ui-testing --jellyspace-perf "http://127.0.0.1:8765/${PERF_VIDEO:-perf.mkv}" "$@")
pid=${launch##*: }
echo "$LABEL: pid $pid"
# Opening the video, then the controls hide four seconds after it plays.
sleep 20
xcrun simctl io "$SIM" screenshot "$OUT/$file-start.png" >/dev/null 2>&1 || true
seconds() { ps -o time= -p "$1" | awk -F'[:.]' '{ n = NF; s = $(n-1) + $n / 100; if (n >= 3) s += $(n-2) * 60; if (n >= 4) s += $(n-3) * 3600; print s }'; }
# Logical writes and bytes written so far (proc_pid_rusage), "logical disk".
writes() {
  python3 - "$1" <<'PY'
import ctypes, sys
buffer = (ctypes.c_uint64 * 64)()
ok = ctypes.CDLL('/usr/lib/libSystem.B.dylib').proc_pid_rusage(int(sys.argv[1]), 4, ctypes.byref(buffer)) == 0
fields = list(buffer)[2:]
print(f"{fields[27]} {fields[17]}" if ok else "0 0")
PY
}
# GPU and energy for the same 45 seconds (powermetrics needs root: left out without it).
power="$OUT/$file.power.plist"
rm -f "$power"
sudo -n powermetrics -i 1000 -n 45 --samplers tasks,gpu_power --show-process-gpu --show-process-energy -f plist -o "$power" >/dev/null 2>&1 &
powerpid=$!
before=$(seconds "$pid"); started=$(date +%s); writtenBefore=$(writes "$pid")
: > "$OUT/$file.samples"
for _ in $(seq 1 45); do
  ps -o %cpu=,rss= -p "$pid" >> "$OUT/$file.samples" || { echo "$LABEL: the app quit"; break; }
  sleep 1
done
after=$(seconds "$pid" || echo "$before"); ended=$(date +%s); writtenAfter=$(writes "$pid")
wait "$powerpid" 2>/dev/null || true
xcrun simctl io "$SIM" screenshot "$OUT/$file-end.png" >/dev/null 2>&1 || true
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
python3 - "$OUT/$file.samples" "$LABEL" "$before" "$after" "$started" "$ended" "$pid" "$power" "$writtenBefore" "$writtenAfter" >> "$OUT/results.md" <<'PY'
import plistlib, statistics, sys
path, label, before, after, started, ended, pid, power, written_before, written_after = sys.argv[1:11]
rows = [line.split() for line in open(path) if line.strip()]
if len(rows) < 10:
    print(f"| {label} | the app quit after {len(rows)} s | | | | | | | |")
    raise SystemExit
cpu = [float(row[0]) for row in rows]
memory = max(int(row[1]) for row in rows) / 1024
wall = max(1, int(ended) - int(started))
used = float(after) - float(before)
logical = (int(written_after.split()[0]) - int(written_before.split()[0])) / wall / 1024

# powermetrics: one plist per sample, separated by NUL bytes.
app_gpu, mac_gpu, energy = [], [], []
try:
    data = open(power, 'rb').read()
except OSError:
    data = b''
for chunk in data.split(b'\0'):
    chunk = chunk.strip()
    if not chunk:
        continue
    try:
        sample = plistlib.loads(chunk)
    except Exception:  # noqa: BLE001
        continue
    for task in sample.get('tasks', []):
        if str(task.get('pid')) == pid or task.get('name') == 'TwilDiary':
            if 'gputime_ms_per_s' in task:
                app_gpu.append(float(task['gputime_ms_per_s']) / 10)  # ms per second -> % of one GPU
            if 'energy_impact' in task:
                energy.append(float(task['energy_impact']))
            break
    gpu = sample.get('gpu', {})
    if 'idle_ratio' in gpu:
        mac_gpu.append((1 - float(gpu['idle_ratio'])) * 100)

def mean(values, fmt):
    return fmt.format(statistics.mean(values)) if values else 'n/a'

print(f"| {label} | {100 * used / wall:.1f}% | {statistics.median(cpu):.1f}% | {max(cpu):.1f}% "
      f"| {mean(app_gpu, '{:.1f}%')} | {mean(mac_gpu, '{:.0f}%')} | {mean(energy, '{:.1f}')} "
      f"| {memory:.0f} MB | {logical:.0f} KB/s |")
PY
tail -1 "$OUT/results.md"
