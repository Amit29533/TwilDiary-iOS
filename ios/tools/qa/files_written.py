"""The files a process wrote most, from an fs_usage capture (`fs_usage -w -f filesys <pid>`).
Prints a Markdown table, or nothing when the capture is empty (fs_usage needs root).
Usage: files_written.py <fs_usage output> <label>"""
import collections
import re
import sys

WRITES = re.compile(r'\b(write|pwrite|writev|pwritev|WrData|WrMeta|fsync|ftruncate|rename)\b')
UUID = re.compile(r'/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}')

path, label = sys.argv[1], sys.argv[2]
try:
    lines = open(path, errors='replace').read().splitlines()
except OSError:
    lines = []
written = collections.Counter()
for line in lines:
    if not WRITES.search(line):
        continue
    found = re.search(r'(/\S+)', line)
    if found:
        written[UUID.sub('/{uuid}', found.group(1))[:140]] += 1
if written:
    print(f'\n{label}: the files written most (fs_usage):\n')
    print('| File | Writes |\n|---|---|')
    for name, count in written.most_common(12):
        print(f'| `{name}` | {count} |')
    print()
