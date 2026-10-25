#!/usr/bin/env python3
"""Bound a CI process even if the test runner hangs after reporting its results."""
import os
import signal
import subprocess
import sys


def run(command: list[str], seconds: float, grace: float = 10) -> int:
    process = subprocess.Popen(command, start_new_session=os.name == 'posix')
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        print(f'error: CI command exceeded its {seconds:g}-second limit: {command[0]}', flush=True)
        if os.name == 'posix':
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            if os.name == 'posix':
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.wait()
        return 124


if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit('Usage: run-bounded.py SECONDS COMMAND [ARG ...]')
    raise SystemExit(run(sys.argv[2:], float(sys.argv[1])))
