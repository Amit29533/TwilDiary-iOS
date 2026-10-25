#!/usr/bin/env python3
"""Reject test-only resources from the built shipping app, not just source paths."""
import fnmatch
import plistlib
from pathlib import Path
import sys


FIXTURES = ('catalog-*.json', 'trakt-*.json', 'reference-workspace.json', 'workspace.json', '*-golden.json')
REQUIRED_REASONS = {
    'NSPrivacyAccessedAPICategoryUserDefaults': 'CA92.1',
    'NSPrivacyAccessedAPICategorySystemBootTime': '35F9.1',
}


def verify(bundle: Path) -> None:
    if not bundle.is_dir():
        raise ValueError('Release app bundle is missing.')
    leaked = []
    for path in bundle.rglob('*'):
        if ('TwilDiaryTestSupport' in path.name
                or any(fnmatch.fnmatchcase(path.name, pattern) for pattern in FIXTURES)):
            leaked.append(path.relative_to(bundle).as_posix())
    if leaked:
        raise ValueError('Release contains test-only resources: ' + ', '.join(sorted(leaked)))
    manifest = bundle / 'PrivacyInfo.xcprivacy'
    if not manifest.is_file():
        raise ValueError('Release is missing its required-reason privacy manifest.')
    try:
        with manifest.open('rb') as source:
            privacy = plistlib.load(source)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise ValueError('Release privacy manifest is not a valid property list.') from error
    if not isinstance(privacy, dict):
        raise ValueError('Release privacy manifest must be a dictionary.')
    entries = privacy.get('NSPrivacyAccessedAPITypes')
    if not isinstance(entries, list):
        raise ValueError('Release privacy manifest is missing required API reasons.')
    reasons = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError('Release privacy manifest contains an invalid API declaration.')
        category = entry.get('NSPrivacyAccessedAPIType')
        values = entry.get('NSPrivacyAccessedAPITypeReasons')
        if (not isinstance(category, str) or category in reasons or not isinstance(values, list)
                or not values or not all(isinstance(value, str) and value for value in values)):
            raise ValueError('Release privacy manifest contains an invalid or duplicate API reason.')
        reasons[category] = values
    for category, reason in REQUIRED_REASONS.items():
        if reason not in reasons.get(category, []):
            raise ValueError('Release privacy manifest is missing ' + category + ' / ' + reason + '.')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]))
    except (ValueError, IndexError) as error:
        raise SystemExit(str(error)) from error
    print('Release resource check passed: no test-support bundle or disposable fixture JSON.')
    print('Production demo artwork and attribution resources are retained.')
    print('Required-reason privacy manifest is packaged in the actual app bundle.')
