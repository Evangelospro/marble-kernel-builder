#!/usr/bin/env python3
"""Extract selected partitions from an Android OTA zip's payload.bin over HTTP
range requests, without downloading the whole (multi-GB) zip.

Usage: remote_payload.py <zip-url> <outdir> <partition> [<partition>...]
Partitions missing from the payload are skipped (listed on stdout).
"""
import bz2
import hashlib
import lzma
import os
import struct
import subprocess
import sys
import zlib


def resolve(url):
    out = subprocess.run(["curl", "-sSI", "--max-time", "60", url], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.lower().startswith("location:"):
            return line.split(":", 1)[1].strip()
    return url


class Remote:
    def __init__(self, url):
        self.src = url
        self.url = resolve(url)
        self.fetched = 0

    def read(self, off, n):
        if n <= 0:
            return b""
        for attempt in range(4):
            r = subprocess.run(
                ["curl", "-sS", "-f", "--max-time", "600", "-r", f"{off}-{off + n - 1}", self.url],
                capture_output=True)
            if r.returncode == 0 and len(r.stdout) == n:
                self.fetched += n
                return r.stdout
            self.url = resolve(self.src)  # signed URL may have expired
        raise IOError(f"range {off}+{n} failed: {r.stderr.decode()[:200]}")

    def size(self):
        out = subprocess.run(["curl", "-sS", "-D", "-", "-o", "/dev/null", "-r", "0-0", "--max-time", "60", self.url],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            if line.lower().startswith("content-range:"):
                return int(line.rsplit("/", 1)[1])
        raise IOError("no content-range: " + out[:300])


def find_member(rem, name):
    total = rem.size()
    tail_len = min(total, 1 << 17)
    tail = rem.read(total - tail_len, tail_len)
    eocd = tail.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise ValueError("no EOCD")
    cd_size, cd_off = struct.unpack_from("<II", tail, eocd + 12)
    loc = tail.rfind(b"PK\x06\x07")  # zip64 locator
    if loc >= 0:
        z64_off = struct.unpack_from("<Q", tail, loc + 8)[0]
        z64 = rem.read(z64_off, 56)
        cd_size, cd_off = struct.unpack_from("<QQ", z64, 40)
    cd = rem.read(cd_off, cd_size)
    p = 0
    while p < len(cd) and cd[p:p + 4] == b"PK\x01\x02":
        method = struct.unpack_from("<H", cd, p + 10)[0]
        csize, usize = struct.unpack_from("<II", cd, p + 20)
        nlen, elen, clen = struct.unpack_from("<HHH", cd, p + 28)
        lho = struct.unpack_from("<I", cd, p + 42)[0]
        fname = cd[p + 46:p + 46 + nlen].decode()
        extra = cd[p + 46 + nlen:p + 46 + nlen + elen]
        if 0xFFFFFFFF in (csize, usize, lho):
            e = 0
            while e + 4 <= len(extra):
                hid, hlen = struct.unpack_from("<HH", extra, e)
                if hid == 1:
                    vals = list(struct.unpack_from(f"<{hlen // 8}Q", extra, e + 4))
                    if usize == 0xFFFFFFFF: usize = vals.pop(0)
                    if csize == 0xFFFFFFFF: csize = vals.pop(0)
                    if lho == 0xFFFFFFFF: lho = vals.pop(0)
                e += 4 + hlen
        if fname == name:
            lh = rem.read(lho, 30)
            lnlen, lelen = struct.unpack_from("<HH", lh, 26)
            if method != 0:
                raise ValueError(f"{name} is compressed (method {method})")
            return lho + 30 + lnlen + lelen, usize
        p += 46 + nlen + elen + clen
    raise KeyError(name)


def pb_fields(buf):
    """Minimal protobuf reader: yields (field, wiretype, value)."""
    i = 0
    while i < len(buf):
        key, i = varint(buf, i)
        f, wt = key >> 3, key & 7
        if wt == 0:
            v, i = varint(buf, i)
        elif wt == 1:
            v = buf[i:i + 8]; i += 8
        elif wt == 2:
            ln, i = varint(buf, i)
            v = buf[i:i + ln]; i += ln
        elif wt == 5:
            v = buf[i:i + 4]; i += 4
        else:
            raise ValueError(f"wire type {wt}")
        yield f, wt, v


def varint(b, i):
    r = s = 0
    while True:
        c = b[i]; i += 1
        r |= (c & 0x7F) << s; s += 7
        if c < 0x80:
            return r, i


def parse_manifest(m):
    block_size, parts = 4096, []
    for f, wt, v in pb_fields(m):
        if f == 3 and wt == 0:
            block_size = v
        elif f == 13:
            name, ops, size = None, [], None
            for pf, _, pv in pb_fields(v):
                if pf == 1:
                    name = pv.decode()
                elif pf == 8:
                    op = {"type": 0, "data_offset": 0, "data_length": 0, "dst": [], "sha": None}
                    for of, _, ov in pb_fields(pv):
                        if of == 1: op["type"] = ov
                        elif of == 2: op["data_offset"] = ov
                        elif of == 3: op["data_length"] = ov
                        elif of == 6:
                            e = dict((ef, ev) for ef, _, ev in pb_fields(ov))
                            op["dst"].append((e.get(1, 0), e.get(2, 0)))
                        elif of == 8: op["sha"] = ov
                    ops.append(op)
                elif pf == 7:
                    for nf, _, nv in pb_fields(pv):
                        if nf == 1: size = nv
            parts.append((name, ops, size))
    return block_size, parts


def decompress(t, data):
    if t == 0: return data                      # REPLACE
    if t == 1: return bz2.decompress(data)      # REPLACE_BZ
    if t == 8: return lzma.decompress(data)     # REPLACE_XZ
    if t == 14:                                 # REPLACE_ZSTD
        return subprocess.run(["zstd", "-dc"], input=data, capture_output=True, check=True).stdout
    raise ValueError(f"unsupported op type {t}")


def main():
    url, outdir, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
    os.makedirs(outdir, exist_ok=True)
    rem = Remote(url)
    base, psize = find_member(rem, "payload.bin")
    hdr = rem.read(base, 24)
    assert hdr[:4] == b"CrAU", hdr[:4]
    version, msize = struct.unpack_from(">QQ", hdr, 4)
    sig = struct.unpack_from(">I", hdr, 20)[0] if version >= 2 else 0
    hlen = 24 if version >= 2 else 20
    manifest = rem.read(base + hlen, msize)
    data_start = base + hlen + msize + sig
    bs, parts = parse_manifest(manifest)
    print("partitions:", ", ".join(f"{n}({(s or 0)//1048576}M)" for n, _, s in parts))
    for name, ops, size in parts:
        if name not in wanted:
            continue
        path = os.path.join(outdir, name + ".img")
        with open(path, "wb") as out:
            out.truncate(size or 0)
            for op in ops:
                if op["type"] in (6, 7):  # ZERO / DISCARD
                    continue
                data = rem.read(data_start + op["data_offset"], op["data_length"])
                if op["sha"] and hashlib.sha256(data).digest() != op["sha"]:
                    raise ValueError(f"{name}: data hash mismatch")
                raw = decompress(op["type"], data)
                pos = 0
                for start, nblk in op["dst"]:
                    n = nblk * bs
                    out.seek(start * bs)
                    out.write(raw[pos:pos + n])
                    pos += n
        print(f"{name}: {size} bytes -> {path}")
    missing = sorted(set(wanted) - {n for n, _, _ in parts})
    if missing:
        print("not in payload:", ", ".join(missing))
    print(f"downloaded {rem.fetched / 1048576:.1f} MiB")


if __name__ == "__main__":
    main()
