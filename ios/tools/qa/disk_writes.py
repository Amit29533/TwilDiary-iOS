"""How much a running process writes to disk: its logical writes (what iOS's "disk writes" report
counts as file-backed memory dirtied) and the bytes that reached the disk, over some seconds, from
proc_pid_rusage. Prints a Markdown row: label | logical writes per second | disk writes per second.
Usage: disk_writes.py <pid> <seconds> <label>"""
import ctypes
import sys
import time

RUSAGE_INFO_V4 = 4
libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib')


def usage(pid: int):
    buffer = (ctypes.c_uint64 * 64)()
    if libc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(buffer)) != 0:
        return None
    fields = list(buffer)[2:]  # after the 16-byte uuid
    return {'disk_written': fields[17], 'logical_writes': fields[27], 'footprint': fields[7]}


def main() -> None:
    pid, seconds, label = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
    first = usage(pid)
    if first is None:
        print(f'| {label} | the app quit | | |')
        return
    time.sleep(seconds)
    last = usage(pid)
    if last is None:
        print(f'| {label} | the app quit | | |')
        return
    logical = (last['logical_writes'] - first['logical_writes']) / seconds / 1024
    disk = (last['disk_written'] - first['disk_written']) / seconds / 1024
    per_day = logical * 86400 / 1024 / 1024
    print(f'| {label} | {logical:.1f} KB/s | {disk:.1f} KB/s | {per_day:.2f} GB a day at this rate (iOS warns at 1 GB) |')


if __name__ == '__main__':
    main()
