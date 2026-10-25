#!/usr/bin/env python3
"""Fail immediately when Xcode reports a tool warning despite exit status zero."""
from pathlib import Path
import re
import sys


def verify(text: str, success_marker: str) -> None:
    warnings = [line for line in text.splitlines() if re.search(r'\bwarning:', line, re.I)]
    if success_marker not in text:
        raise ValueError('Build success marker is missing: ' + success_marker)
    if warnings:
        raise ValueError('Build warnings are not accepted:\n' + '\n'.join(warnings[:20]))


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]).read_text(errors='replace'), sys.argv[2])
    except (ValueError, IndexError) as error:
        raise SystemExit(str(error)) from error
    print('Build log accepted: success marker and zero tool/compiler warnings.')
