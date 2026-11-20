#!/usr/bin/env python3
"""Check that a ROM's kernel modules can load on our freshly built kernel.

For every .ko found under the given module directories (the ROM's vendor_boot
ramdisk, vendor_dlkm, system_dlkm):
  * every symbol it imports (its __versions table) must be exported by our
    vmlinux with the *same* CRC, or be exported by another ROM module;
  * its struct module (.gnu.linkonce.this_module) must have our size;
  * its vermagic flags (after the release) must equal ours.
Any violation means the module would be rejected at boot, so the phone would
not boot: exit status 1.

Usage: rom_modcheck.py --vmlinux V --symvers S --report R DIR [DIR...]
       rom_modcheck.py --vmlinux V --symvers S --report R --profile P.json
       rom_modcheck.py --dump-profile P.json DIR [DIR...]

A profile is the compact list of what the ROM's modules require (imports with
CRCs, symbols they export to each other, struct module sizes, vermagic flags),
so a ROM can be checked without downloading it again.
"""
import json
import argparse
import os
import re
import struct
import subprocess
import sys


def elf_sections(data):
    if data[:4] != b"\x7fELF" or data[4] != 2:
        raise ValueError("not ELF64")
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    secs = []
    for i in range(shnum):
        o = shoff + i * shentsize
        name, typ, _flags, _addr, off, size = struct.unpack_from("<IIQQQQ", data, o)
        secs.append((name, typ, off, size))
    _, _, stroff, strsize = secs[shstrndx]
    strtab = data[stroff:stroff + strsize]
    out = {}
    for name, typ, off, size in secs:
        n = strtab[name:strtab.index(b"\0", name)].decode()
        out[n] = (typ, off, size)
    return out


def cstr(b):
    return b.split(b"\0", 1)[0].decode(errors="replace")


def module_info(path):
    data = open(path, "rb").read()
    secs = elf_sections(data)
    versions = []
    if "__versions" in secs:
        _, off, size = secs["__versions"]
        for o in range(off, off + size, 64):
            crc = struct.unpack_from("<Q", data, o)[0] & 0xFFFFFFFF
            versions.append((cstr(data[o + 8:o + 64]), crc))
    this_size = secs.get(".gnu.linkonce.this_module", (0, 0, None))[2]
    exports = set()
    if ".symtab" in secs and ".strtab" in secs:
        _, soff, ssize = secs[".symtab"]
        _, toff, tsize = secs[".strtab"]
        strtab = data[toff:toff + tsize]
        for o in range(soff, soff + ssize, 24):
            nidx = struct.unpack_from("<I", data, o)[0]
            name = strtab[nidx:strtab.index(b"\0", nidx)].decode(errors="replace")
            if name.startswith("__ksymtab_"):
                exports.add(name[len("__ksymtab_"):])
    vermagic = ""
    if ".modinfo" in secs:
        _, off, size = secs[".modinfo"]
        for item in data[off:off + size].split(b"\0"):
            if item.startswith(b"vermagic="):
                vermagic = item[9:].decode(errors="replace")
    return versions, this_size, exports, vermagic


def our_exports(symvers):
    crcs = {}
    for line in open(symvers, encoding="utf-8", errors="replace"):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 2 and f[0].startswith("0x"):
            crcs[f[1]] = int(f[0], 16) & 0xFFFFFFFF
    return crcs


def struct_module_size(vmlinux):
    out = subprocess.run(["pahole", "-C", "module", vmlinux], capture_output=True, text=True).stdout
    m = re.search(r"/\* size: (\d+),", out)
    return int(m.group(1)) if m else None


def our_vermagic(vmlinux):
    data = open(vmlinux, "rb").read()
    m = re.search(rb"\x00(\d+\.\d+\.\d+[^\x00 ]* SMP [^\x00]*?) ?\x00", data)
    return m.group(1).decode() if m else ""


def find_modules(dirs):
    mods = []
    for d in dirs:
        for root, _, files in os.walk(d):
            for f in files:
                if f.endswith(".ko"):
                    mods.append(os.path.join(root, f))
    return sorted(mods)


def dump_profile(dirs, out):
    """Per-module requirements, paths relative to the module dirs' parent."""
    mods = find_modules(dirs)
    if not mods:
        raise SystemExit("no modules to profile")
    base = os.path.commonpath([os.path.dirname(d.rstrip("/")) or "." for d in dirs])
    profile = {"format": 1, "modules": {}}
    for p in mods:
        versions, this_size, exports, vermagic = module_info(p)
        profile["modules"][os.path.relpath(p, base)] = {
            "imports": [[s, c] for s, c in versions],
            "this_module_size": this_size,
            "exports": sorted(exports),
            "vermagic": vermagic,
        }
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(profile, fh, separators=(",", ":"), sort_keys=True)
    print(f"profile: {len(mods)} modules -> {out}")


def load_profile(path):
    profile = json.load(open(path, encoding="utf-8"))
    if profile.get("format") != 1:
        raise SystemExit(f"{path}: unknown profile format")
    infos, mod_exports = {}, set()
    for name, m in profile["modules"].items():
        exports = set(m["exports"])
        mod_exports |= exports
        infos[name] = ([(s, c) for s, c in m["imports"]], m["this_module_size"], exports, m["vermagic"])
    return infos, mod_exports


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vmlinux")
    ap.add_argument("--symvers")
    ap.add_argument("--report")
    ap.add_argument("--profile")
    ap.add_argument("--dump-profile")
    ap.add_argument("dirs", nargs="*")
    a = ap.parse_args()

    if a.dump_profile:
        dump_profile(a.dirs, a.dump_profile)
        return 0
    if not (a.vmlinux and a.symvers and a.report) or not (a.dirs or a.profile):
        ap.error("--vmlinux, --symvers, --report and module DIRs or --profile are required")

    crcs = our_exports(a.symvers)
    mod_size = struct_module_size(a.vmlinux)
    vm = our_vermagic(a.vmlinux)
    vm_flags = vm.split(" ", 1)[1].strip() if " " in vm else ""

    if a.profile:
        infos, mod_exports = load_profile(a.profile)
    else:
        infos = {os.path.relpath(p): module_info(p) for p in find_modules(a.dirs)}
        mod_exports = set()
        for _, _, exp, _ in infos.values():
            mod_exports |= exp
    mods = list(infos)

    problems, checked_syms = [], 0
    if not mods:
        problems.append("no ROM modules found")
    if not crcs:
        problems.append(f"no exports with CRCs in {a.symvers}")
    if mod_size is None:
        problems.append("could not determine our sizeof(struct module) (pahole)")
    if not vm_flags:
        problems.append("could not find our vermagic string in vmlinux")
    for name, (versions, this_size, _, vermagic) in infos.items():
        if mod_size is not None and this_size is not None and this_size != mod_size:
            problems.append(f"{name}: struct module is {this_size} bytes, ours is {mod_size}")
        mflags = vermagic.split(" ", 1)[1].strip() if " " in vermagic else ""
        if vm_flags and mflags and mflags != vm_flags:
            problems.append(f"{name}: vermagic flags '{mflags}' != ours '{vm_flags}'")
        for sym, crc in versions:
            checked_syms += 1
            if sym in crcs:
                if crcs[sym] != crc:
                    problems.append(f"{name}: {sym} CRC 0x{crc:08x} != ours 0x{crcs[sym]:08x}")
            elif sym not in mod_exports:
                problems.append(f"{name}: needs {sym}, which our kernel does not export")

    with open(a.report, "w", encoding="utf-8") as r:
        r.write(f"modules checked: {len(mods)}\n")
        r.write(f"symbol imports checked: {checked_syms}\n")
        r.write(f"our exports with CRC: {len(crcs)}\n")
        r.write(f"sizeof(struct module): {mod_size}\n")
        r.write(f"vermagic: {vm}\n")
        r.write(f"problems: {len(problems)}\n")
        for line in problems:
            r.write(f"  {line}\n")
    print(open(a.report).read(), end="")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
