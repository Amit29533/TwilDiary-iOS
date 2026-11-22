"""A Markdown table of an xcresult's tests: each test's result, time and first failure.
Usage: test_results.py <Result.xcresult> <title>"""
import json
import subprocess
import sys


def walk(node, found):
    if node.get('nodeType') == 'Test Case':
        failures = [child.get('name', '') for child in node.get('children', []) if child.get('nodeType') == 'Failure Message']
        found.append((node.get('name', '?'), node.get('result', '?'), node.get('duration', ''), failures))
    for child in node.get('children', []):
        walk(child, found)


def main() -> None:
    path, title = sys.argv[1], sys.argv[2]
    out = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', path],
                         capture_output=True, text=True)
    print(f'### {title}\n')
    if out.returncode != 0:
        print('No test results (' + out.stderr.strip()[:300] + ')\n')
        return
    found = []
    for node in json.loads(out.stdout).get('testNodes', []):
        walk(node, found)
    passed = sum(1 for f in found if f[1] == 'Passed')
    failed = sum(1 for f in found if f[1] == 'Failed')
    skipped = sum(1 for f in found if f[1] == 'Skipped')
    print(f'{passed} passed, {failed} failed, {skipped} skipped\n')
    print('| Test | Result | Time | First failure |')
    print('|---|---|---|---|')
    for name, result, duration, failures in found:
        first = failures[0].replace('|', '/').replace('\n', ' ')[:220] if failures else ''
        mark = {'Passed': 'pass', 'Failed': '**FAIL**', 'Skipped': 'skipped'}.get(result, result)
        print(f'| {name} | {mark} | {duration} | {first} |')
    print()


if __name__ == '__main__':
    main()
