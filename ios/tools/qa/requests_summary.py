"""What JellySpace asked the stand-in server (fake_jellyfin.py's log): each kind of request and how
often, and the ones answered with an error. Usage: requests_summary.py <log>"""
import collections
import re
import sys

IDS = re.compile(r'/(m\d+|m-wide|s\d(?:-s\d(?:e\d+)?)?|lib-\w+|qa-user|[0-9a-f]{32})(?=/|$|\?)')

rows = [line.rstrip('\n').split('\t') for line in open(sys.argv[1]) if line.count('\t') >= 4]
print('### Requests JellySpace made to the server\n')
print(f'{len(rows)} requests in all.\n')
kinds = collections.Counter()
errors = collections.Counter()
slowest = collections.defaultdict(float)
for at, method, status, ms, path in rows:
    key = method + ' ' + re.sub(r'\?.*', '', IDS.sub('/{id}', path))
    kinds[key] += 1
    slowest[key] = max(slowest[key], float(ms))
    if not status.startswith('2'):
        errors[key + ' → ' + status] += 1
print('| Request | Times | Slowest |\n|---|---|---|')
for key, count in kinds.most_common(35):
    print(f'| `{key}` | {count} | {slowest[key]:.0f} ms |')
if errors:
    print('\nAnswered with an error (the stand-in lacks it, or the app asked for something odd):\n')
    print('| Request | Times |\n|---|---|')
    for key, count in errors.most_common(20):
        print(f'| `{key}` | {count} |')
print()
