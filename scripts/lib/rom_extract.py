#!/usr/bin/env python3
"""Pull the pieces of a ROM that the kernel must match.

  rom_extract.py kernel   <boot.img> <out-kernel>       kernel of a boot image (v0-v4)
  rom_extract.py ikconfig <kernel> <out-config>         embedded .config (CONFIG_IKCONFIG)
  rom_extract.py release  <kernel>                      print "Linux version" release
  rom_extract.py vendor-ramdisks <vendor_boot.img> <outdir>
                                                        unpack every vendor ramdisk (v3/v4)
"""
import gzip
import os
import re
import struct
import subprocess
import sys


def align(x, page):
    return (x + page - 1) // page * page


def boot_kernel(path, out):
    b = open(path, "rb").read()
    if b[:8] != b"ANDROID!":
        raise SystemExit(f"{path}: not an Android boot image")
    ksize = struct.unpack_from("<I", b, 8)[0]
    hver = struct.unpack_from("<I", b, 40)[0]
    page = 4096 if hver >= 3 else struct.unpack_from("<I", b, 36)[0]
    kernel = b[page:page + ksize]
    for magic, cmd in ((b"\x1f\x8b", ["gzip", "-dc"]), (b"\x02\x21\x4c\x18", ["lz4", "-dc"]),
                       (b"\x04\x22\x4d\x18", ["lz4", "-dc"])):
        if kernel.startswith(magic):
            kernel = subprocess.run(cmd, input=kernel, capture_output=True, check=True).stdout
            break
    open(out, "wb").write(kernel)


def ikconfig(kernel, out):
    b = open(kernel, "rb").read()
    s = b.find(b"IKCFG_ST")
    e = b.find(b"IKCFG_ED", s)
    if s < 0 or e < 0:
        raise SystemExit(f"{kernel}: no embedded config (CONFIG_IKCONFIG not set)")
    open(out, "wb").write(gzip.decompress(b[s + 8:e]))


def release(kernel):
    b = open(kernel, "rb").read()
    m = re.search(rb"Linux version (\d+\.\d+[^ \x00]*) \(", b)
    print(m.group(1).decode() if m else "")


def vendor_ramdisks(path, outdir):
    b = open(path, "rb").read()
    if b[:8] != b"VNDRBOOT":
        raise SystemExit(f"{path}: not a vendor_boot image")
    hver, page, _k, _r, vrsize = struct.unpack_from("<IIIII", b, 8)
    off = 28 + 2048 + 4 + 16
    hsize, dtbsize = struct.unpack_from("<II", b, off)
    rd_off = align(hsize, page)
    pieces = [("default", 0, vrsize)]
    if hver >= 4:
        tsize, tnum, tent = struct.unpack_from("<III", b, off + 16)
        tab_off = rd_off + align(vrsize, page) + align(dtbsize, page)
        pieces = []
        for i in range(tnum):
            e = tab_off + i * tent
            size, offset, _typ = struct.unpack_from("<III", b, e)
            name = b[e + 12:e + 44].split(b"\0")[0].decode() or f"ramdisk{i}"
            pieces.append((name, offset, size))
    for name, offset, size in pieces:
        data = b[rd_off + offset:rd_off + offset + size]
        raw = b""
        for cmd in (["lz4", "-dc"], ["gzip", "-dc"]):
            r = subprocess.run(cmd, input=data, capture_output=True)
            if r.returncode == 0 and r.stdout:
                raw = r.stdout
                break
        if not raw:
            raise SystemExit(f"{path}: cannot decompress ramdisk {name}")
        d = os.path.join(outdir, name)
        os.makedirs(d, exist_ok=True)
        subprocess.run(["cpio", "-idm", "--quiet", "--no-absolute-filenames"], input=raw, cwd=d, check=True)
        print(f"vendor ramdisk {name}: {len(raw)} bytes -> {d}")


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    {"kernel": boot_kernel, "ikconfig": ikconfig, "release": release,
     "vendor-ramdisks": vendor_ramdisks}[cmd](*args)


if __name__ == "__main__":
    main()
