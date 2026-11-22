#!/usr/bin/env bash
# The QA run's test video: 10 minutes of 1080p24 with two audio tracks (English, Japanese) and two
# subtitle tracks (English ASS, Spanish SRT), served with range requests on 127.0.0.1:8765.
# Usage: make_video.sh <folder>
set -euo pipefail
out=$1
mkdir -p "$out"
command -v ffmpeg >/dev/null || brew install ffmpeg
python3 ios/tools/perf/make_subs.py > "$out/subs.ass"
python3 - "$out/subs.srt" <<'PY'
import sys
lines = []
for i in range(300):
    start, end = i * 2, i * 2 + 1.6
    clock = lambda s: '%02d:%02d:%02d,%03d' % (s // 3600, s % 3600 // 60, int(s % 60), int(round((s % 1) * 1000)))
    lines.append(f'{i + 1}\n{clock(start)} --> {clock(end)}\nLínea de prueba número {i + 1}\n')
open(sys.argv[1], 'w', encoding='utf-8').write('\n'.join(lines))
PY
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=1920x1080:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 -f lavfi -i sine=frequency=660:sample_rate=48000 \
  -i "$out/subs.ass" -i "$out/subs.srt" -t 600 \
  -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s -c:v libx264 -preset veryfast -crf 28 -pix_fmt yuv420p \
  -c:a aac -b:a 96k -c:s:0 ass -c:s:1 srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn -metadata:s:s:0 language=eng -metadata:s:s:1 language=spa \
  -disposition:s:0 default "$out/qa.mkv"
ls -l "$out"
cp ios/tools/perf/serve.py "$RUNNER_TEMP/serve.py"
nohup python3 "$RUNNER_TEMP/serve.py" "$out" 8765 > "$RUNNER_TEMP/serve.log" 2>&1 &
sleep 1
curl -sf -r 0-15 -o /dev/null -w 'range request: %{http_code}\n' http://127.0.0.1:8765/qa.mkv
