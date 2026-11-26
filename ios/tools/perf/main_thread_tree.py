#!/usr/bin/env python3
"""The main thread's part of a macOS `sample` report, trimmed to what held it up.

Prints the main thread's call tree with only the branches seen in at least `--share` of its samples
(default 1%), and then the app's own functions ranked by how many main-thread samples were in them.
Used by the navigation probe (ios-namespace-navprobe.yml) on the Simulator app.
"""
import re
import sys

def main(path, share=0.01):
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    start = next((i for i, line in enumerate(lines) if "com.apple.main-thread" in line), None)
    if start is None:
        print("no main thread in the sample"); return
    head = lines[start]
    indent = len(head) - len(head.lstrip())
    total = int(head.split()[0])
    print(f"main thread: {total} samples")
    tree = []
    for line in lines[start + 1:]:
        body = line.lstrip()
        if not body:
            break
        depth = len(line) - len(body)
        if depth <= indent and body[:1].isdigit():
            break  # the next thread
        tree.append(line)
    counts = {}
    for line in tree:
        match = re.match(r"^[\s+!:|]*?(\d+)\s+(.*)$", line)
        if not match:
            continue
        count, rest = int(match.group(1)), match.group(2)
        if count >= total * share:
            print(line[: 220])
        # The app's own frames (its binary is TwilDiary.debug.dylib in a debug build, else TwilDiary).
        frame = re.match(r"^(.*?)\s+\(in (TwilDiary[^)]*)\)", rest)
        if frame:
            name = frame.group(1)
            counts[name] = max(counts.get(name, 0), count)
    print("\napp functions on the main thread (largest share first):")
    for name, count in sorted(counts.items(), key=lambda item: -item[1])[:60]:
        print(f"{count:7d}  {100 * count / max(1, total):5.1f}%  {name[:180]}")

if __name__ == "__main__":
    main(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 0.01)
