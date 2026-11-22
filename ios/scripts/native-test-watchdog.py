#!/usr/bin/env python3
"""Bound an Xcode test invocation and preserve evidence before stopping a stall."""
import argparse
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--label', required=True)
parser.add_argument('--budget', type=int, default=1500)
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ['--'] else args.command
if not command:
    parser.error('A command is required')
root = Path('ios/.artifacts')
diagnostics = root / 'screenshots' / ('stall-' + args.label)


def collect():
    diagnostics.mkdir(parents=True, exist_ok=True)
    def run(name, command, timeout=20):
        try:
            result = subprocess.run(command, capture_output=True, timeout=timeout)
            (diagnostics / name).write_bytes(result.stdout + result.stderr)
            return result.stdout.decode(errors='replace')
        except (OSError, subprocess.TimeoutExpired) as error:
            (diagnostics / name).write_text(str(error))
            return ''
    processes = run('processes.txt', ['ps', '-axo', 'pid,ppid,pcpu,stat,etime,comm'])
    for line in processes.splitlines():
        if '/TwilDiary.app/TwilDiary' in line or '/TwilDiaryUITests-Runner.app/' in line:
            pid = line.strip().split()[0]
            run('sample-' + pid + '.txt', ['sample', pid, '5', '-file', str(diagnostics / ('sample-' + pid + '.trace'))], 15)
    simulator = os.environ.get('SIMULATOR_ID')
    if simulator:
        run('screenshot-command.txt', ['xcrun', 'simctl', 'io', simulator, 'screenshot', str(diagnostics / 'screen.png')])
        run('simulator-errors.txt', ['xcrun', 'simctl', 'spawn', simulator, 'log', 'show', '--last', '2m', '--style', 'compact', '--predicate', 'process == "TwilDiary" OR process == "TwilDiaryUITests-Runner"'])
    print('Stall diagnostics retained at ' + str(diagnostics), flush=True)


process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
started = activity = time.monotonic()
timed_out = False
while selector.get_map():
    for key, _ in selector.select(timeout=1):
        chunk = os.read(key.fileobj.fileno(), 65536)
        if chunk:
            sys.stdout.buffer.write(chunk); sys.stdout.buffer.flush()
            activity = time.monotonic()
        else:
            selector.unregister(key.fileobj)
    now = time.monotonic()
    if now - activity > 180 or now - started > args.budget:
        print('\nNative test watchdog: no output for 180 seconds or invocation budget exceeded. Capturing diagnostics before termination.', flush=True)
        collect()
        timed_out = True
        for sig, wait in [(signal.SIGINT, 15), (signal.SIGTERM, 10), (signal.SIGKILL, 5)]:
            try:
                os.killpg(process.pid, sig)
                process.wait(timeout=wait)
                break
            except subprocess.TimeoutExpired:
                continue
            except ProcessLookupError:
                break
        break
sys.exit(124 if timed_out else process.wait())
