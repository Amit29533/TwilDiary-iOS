"""Sets a built app's main-thread stack size (LC_MAIN's stacksize) and signs it again (ad hoc).

The Simulator gives an app's main thread the Mac's 8 MB stack; an iPhone gives it 1 MB, so a view
that runs the main thread out of stack crashes on the phone and not in the Simulator. The QA run
sets the phone's size so the Simulator crashes the same way.
Usage: stack_size.py <App.app> <size in KB>"""
import os
import plistlib
import struct
import subprocess
import sys

LC_MAIN = 0x80000028
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF


def patch_slice(data: bytearray, offset: int, size: int) -> bool:
    magic, = struct.unpack_from('<I', data, offset)
    if magic != MH_MAGIC_64:
        return False
    ncmds, = struct.unpack_from('<I', data, offset + 16)
    at = offset + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, at)
        if cmd == LC_MAIN:
            entry, old = struct.unpack_from('<QQ', data, at + 8)
            struct.pack_into('<Q', data, at + 16, size)
            print(f'LC_MAIN stacksize {old} -> {size}')
            return True
        at += cmdsize
    return False


def main() -> None:
    app, kb = sys.argv[1], int(sys.argv[2])
    size = kb * 1024
    if size % 16384:
        raise SystemExit('The size must be a multiple of 16 KB')
    info = plistlib.load(open(os.path.join(app, 'Info.plist'), 'rb'))
    binary = os.path.join(app, info['CFBundleExecutable'])
    data = bytearray(open(binary, 'rb').read())
    magic, = struct.unpack_from('>I', data, 0)
    patched = False
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count, = struct.unpack_from('>I', data, 4)
        for i in range(count):
            if magic == FAT_MAGIC:
                _, _, off, _, _ = struct.unpack_from('>IIIII', data, 8 + i * 20)
            else:
                _, _, off, _, _, _ = struct.unpack_from('>IIQQII', data, 8 + i * 32)
            patched |= patch_slice(data, off, size)
    else:
        patched = patch_slice(data, 0, size)
    if not patched:
        raise SystemExit('No LC_MAIN found in ' + binary)
    open(binary, 'wb').write(data)
    subprocess.run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements', binary], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements', app], check=True)
    print('signed', app)


if __name__ == '__main__':
    main()
