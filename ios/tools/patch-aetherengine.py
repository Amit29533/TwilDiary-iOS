#!/usr/bin/env python3
"""Patches one expression in AetherEngine's PerFrameBenchmark.swift after the package is checked out.

Xcode 26.6's Swift gives up type-checking `keyFramePacket(sliceBytes:)` ("unable to type-check this
expression in reasonable time"); AetherEngine supports Xcode 27, and its own Xcode 26 check runs 26.3,
which still copes. The same bytes are built step by step here, so the function returns exactly what
it did. Only this checkout changes (LGPL-3.0: the engine's source, patched, is the public upstream plus
this file). Idempotent; fails loudly if the upstream code changes, so a stale patch never builds silently.
"""
import os
import pathlib
import stat
import sys

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "ios/.spm")
TARGET = ROOT / "checkouts/AetherEngine/Sources/AetherEngine/Diagnostics/PerFrameBenchmark.swift"
MARK = "// TwilDiary patch: built step by step for Xcode 26.6"

OLD = """        let nals: [[UInt8]] = [[35 << 1, 1, 0x50], sei]
            + (0 ..< 4).map { i in [19 << 1, 1] + (0 ..< sliceBytes / 4).map { UInt8(0x11 &+ UInt8(truncatingIfNeeded: $0 &* 7 &+ i)) | 1 } }
        return nals.flatMap { nal in
            [UInt8(nal.count >> 24 & 0xFF), UInt8(nal.count >> 16 & 0xFF), UInt8(nal.count >> 8 & 0xFF),
             UInt8(nal.count & 0xFF)] + nal
        }
"""

NEW = f"""        {MARK}
        var nals: [[UInt8]] = [[35 << 1, 1, 0x50], sei]
        for i in 0 ..< 4 {{
            var slice: [UInt8] = [19 << 1, 1]
            for j in 0 ..< sliceBytes / 4 {{
                let step: UInt8 = UInt8(truncatingIfNeeded: j &* 7 &+ i)
                let value: UInt8 = 0x11 &+ step
                slice.append(value | 1)
            }}
            nals.append(slice)
        }}
        var packet: [UInt8] = []
        for nal in nals {{
            let size: Int = nal.count
            packet.append(UInt8(size >> 24 & 0xFF))
            packet.append(UInt8(size >> 16 & 0xFF))
            packet.append(UInt8(size >> 8 & 0xFF))
            packet.append(UInt8(size & 0xFF))
            packet.append(contentsOf: nal)
        }}
        return packet
"""

# Release builds: Xcode 26.6 reads the key path captured by `median`'s map closure as a data race
# ("sending 'key' risks causing data races"); a plain loop reads the same values.
MARK2 = "// TwilDiary patch: median without a closure for Xcode 26.6"
OLD2 = """        func median(_ key: KeyPath<FrameUpscaler.StageTimes, Double>) -> Double {
            let sorted = steps.map { $0[keyPath: key] }.sorted()
"""
NEW2 = f"""        func median(_ key: KeyPath<FrameUpscaler.StageTimes, Double>) -> Double {{
            {MARK2}
            var values: [Double] = []
            for step in steps {{ values.append(step[keyPath: key]) }}
            let sorted = values.sorted()
"""

if not TARGET.exists():
    sys.exit(f"patch-aetherengine: {TARGET} is missing (packages not resolved?)")
text = TARGET.read_text(encoding="utf-8")
changed = False
for mark, old, new in [(MARK, OLD, NEW), (MARK2, OLD2, NEW2)]:
    if mark in text:
        continue
    if text.count(old) != 1:
        sys.exit("patch-aetherengine: the expected code in PerFrameBenchmark.swift changed upstream; review the patch")
    text = text.replace(old, new)
    changed = True
if not changed:
    print("patch-aetherengine: already patched")
    sys.exit(0)
# Package checkouts are read-only: this one file is made writable first.
os.chmod(TARGET, os.stat(TARGET).st_mode | stat.S_IWUSR)
TARGET.write_text(text, encoding="utf-8")
print("patch-aetherengine: patched", TARGET)
