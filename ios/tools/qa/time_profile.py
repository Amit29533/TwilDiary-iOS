"""The heaviest functions in a Time Profiler export (xctrace export of the time-profile table).
Prints the top leaf functions overall, and the app's own functions by inclusive time.
Usage: time_profile.py <export.xml> <title>"""
import collections
import sys
import xml.etree.ElementTree as ET


def main() -> None:
    path, title = sys.argv[1], sys.argv[2]
    try:
        root = ET.parse(path).getroot()
    except Exception as error:  # noqa: BLE001
        print(f'### {title}\n\nNo profile ({error})\n')
        return
    ids = {}
    for element in root.iter():
        if 'id' in element.attrib:
            ids[element.attrib['id']] = element

    def resolve(element):
        return ids.get(element.attrib['ref'], element) if 'ref' in element.attrib else element

    leaf = collections.Counter()
    own = collections.Counter()
    threads = collections.Counter()
    total = 0
    for row in root.iter('row'):
        weight_el = row.find('weight')
        weight = int(resolve(weight_el).text or 0) if weight_el is not None else 1
        thread_el = row.find('thread')
        thread = resolve(thread_el).attrib.get('fmt', '?') if thread_el is not None else '?'
        backtrace = row.find('backtrace')
        if backtrace is None:
            continue
        backtrace = resolve(backtrace)
        frames = [resolve(frame) for frame in backtrace.findall('frame')]
        if not frames:
            continue
        total += weight
        threads[thread.split(' (')[0][:60]] += weight
        leaf[frames[0].attrib.get('name', '?')[:120]] += weight
        seen = set()
        for frame in frames:
            binary = frame.find('binary')
            binary_name = resolve(binary).attrib.get('name', '') if binary is not None else ''
            if binary_name in ('TwilDiary', 'TwilDiary.debug.dylib'):
                name = frame.attrib.get('name', '?')[:120]
                if name not in seen:
                    seen.add(name)
                    own[name] += weight
    print(f'### {title}\n')
    if not total:
        print('No samples\n')
        return
    print('Threads by CPU time:\n')
    print('| Thread | Share |\n|---|---|')
    for name, weight in threads.most_common(8):
        print(f'| {name} | {100 * weight / total:.1f}% |')
    print('\nHeaviest functions (where the time is spent):\n')
    print('| Function | Share |\n|---|---|')
    for name, weight in leaf.most_common(15):
        print(f'| `{name}` | {100 * weight / total:.1f}% |')
    print("\nThe app's own code (including what it calls):\n")
    print('| Function | Share |\n|---|---|')
    for name, weight in own.most_common(15):
        print(f'| `{name}` | {100 * weight / total:.1f}% |')
    print()


if __name__ == '__main__':
    main()
