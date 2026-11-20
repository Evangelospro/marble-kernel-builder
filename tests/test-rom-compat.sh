#!/usr/bin/env bash
# Target-ROM safety checks:
#  - rom_modcheck.py rejects CRC mismatches, missing exports, struct module
#    size and vermagic differences, and accepts a matching kernel;
#  - verify-rom-compat.sh rejects unexpected config differences and a
#    different kernel commit, and accepts toolchain/LTO/KSU-only differences;
#  - anykernel.sh check_kernel_series refuses series/commit mismatches and
#    unreadable versions unless a force flash is requested.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# ── synthetic modules / kernel ──
python3 - "${tmp_dir}" <<'PY'
import os, struct, sys
d = sys.argv[1]

def elf(sections):
    """sections: list of (name, bytes); adds .shstrtab; returns ELF64 bytes."""
    names = b"\0" + b"".join(n.encode() + b"\0" for n, _ in sections) + b".shstrtab\0"
    body, offs, off = b"", [], 64
    for _, data in sections + [(".shstrtab", names)]:
        offs.append((off, len(data)))
        body += data
        off += len(data)
    shoff = off
    hdr = bytearray(64)
    hdr[0:4] = b"\x7fELF"; hdr[4] = 2; hdr[5] = 1
    struct.pack_into("<Q", hdr, 0x28, shoff)
    struct.pack_into("<HHH", hdr, 0x3A, 64, len(sections) + 2, len(sections) + 1)
    sh = bytes(64)
    pos = 1
    for i, (n, _) in enumerate(sections + [(".shstrtab", names)]):
        o, sz = offs[i]
        sh += struct.pack("<IIQQQQIIQQ", pos, 1, 0, 0, o, sz, 0, 0, 1, 0)
        pos += len(n) + 1
    return bytes(hdr) + body + sh

def versions(entries):
    return b"".join(struct.pack("<Q", crc) + name.encode().ljust(56, b"\0") for name, crc in entries)

def symtab(names):
    strtab = b"\0" + b"".join(n.encode() + b"\0" for n in names)
    syms, p = bytes(24), 1
    for n in names:
        syms += struct.pack("<IBBHQQ", p, 0, 0, 0, 0, 0)
        p += len(n) + 1
    return syms, strtab

def module(path, imports, exports=(), this=1024, vermagic="5.10.1-g0123456789ab SMP preempt mod_unload modversions aarch64"):
    syms, strtab = symtab([f"__ksymtab_{e}" for e in exports])
    secs = [("__versions", versions(imports)), (".gnu.linkonce.this_module", bytes(this)),
            (".modinfo", f"license=GPL\0vermagic={vermagic}\0".encode()),
            (".symtab", syms), (".strtab", strtab)]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(elf(secs))

good = os.path.join(d, "rom-good")
module(f"{good}/a.ko", [("module_layout", 0x11111111), ("printk", 0x22222222), ("b_func", 0x33333333)])
module(f"{good}/b.ko", [("printk", 0x22222222)], exports=["b_func"])
module(f"{d}/rom-crc/a.ko", [("printk", 0xdeadbeef)])
module(f"{d}/rom-missing/a.ko", [("not_exported", 0x1)])
module(f"{d}/rom-size/a.ko", [("printk", 0x22222222)], this=1536)
module(f"{d}/rom-magic/a.ko", [("printk", 0x22222222)], vermagic="5.10.1 SMP mod_unload aarch64")

open(f"{d}/vmlinux.symvers", "w").write(
    "0x11111111\tmodule_layout\tvmlinux\tEXPORT_SYMBOL\t\n0x22222222\tprintk\tvmlinux\tEXPORT_SYMBOL\t\n")
open(f"{d}/vmlinux", "wb").write(
    b"junk\0Linux version 5.10.1-g0123456789ab (x@y) (clang) #1\0"
    b"5.10.1-g0123456789ab SMP preempt mod_unload modversions aarch64 \0more")
PY
mkdir -p "${tmp_dir}/bin"
printf '#!/bin/sh\necho "struct module {"; echo "\t/* size: 1024, cachelines: 16, members: 50 */"; echo "};"\n' > "${tmp_dir}/bin/pahole"
chmod +x "${tmp_dir}/bin/pahole"

modcheck() {
  PATH="${tmp_dir}/bin:${PATH}" python3 -I "${repo_root}/scripts/lib/rom_modcheck.py" \
    --vmlinux "${tmp_dir}/vmlinux" --symvers "${tmp_dir}/vmlinux.symvers" --report "${tmp_dir}/r.txt" "$@" >/dev/null
}
modcheck "${tmp_dir}/rom-good" || { cat "${tmp_dir}/r.txt"; fail "matching kernel rejected"; }
grep -q '^problems: 0$' "${tmp_dir}/r.txt" || fail "report should show 0 problems"
for case in crc:CRC missing:"does not export" size:"struct module is 1536" magic:vermagic; do
  dir="${case%%:*}"; want="${case#*:}"
  if modcheck "${tmp_dir}/rom-${dir}"; then fail "modcheck accepted rom-${dir}"; fi
  grep -q "${want}" "${tmp_dir}/r.txt" || fail "rom-${dir}: expected '${want}' in report"
done

# ── verify-rom-compat.sh ──
w="${tmp_dir}/work"
mkdir -p "${w}/scripts/lib" "${w}/config" "${w}/release" "${w}/rom/modules" "${w}/k/out/arch/arm64/boot" "${w}/k/release"
cp "${repo_root}/config/marble.env" "${w}/config/"
cp "${repo_root}/scripts/verify-rom-compat.sh" "${w}/scripts/"
cp "${repo_root}/scripts/lib/rom_modcheck.py" "${repo_root}/scripts/lib/rom_extract.py" "${w}/scripts/lib/"
cp -r "${tmp_dir}/rom-good" "${w}/rom/modules/good"
cp "${tmp_dir}/vmlinux" "${tmp_dir}/vmlinux.symvers" "${w}/k/out/"
cp "${tmp_dir}/vmlinux" "${w}/k/out/arch/arm64/boot/Image"
cat > "${w}/release/rom-target.env" <<'EOF'
rom_target=Test-ROM.zip
rom_kernel_release=5.10.1-g0123456789ab
rom_kernel_series=5.10
rom_kernel_commit=0123456789ab
EOF
printf 'CONFIG_MODVERSIONS=y\nCONFIG_LTO_CLANG_FULL=y\nCONFIG_CLANG_VERSION=210000\n# CONFIG_MODULE_SIG_PROTECT is not set\n' > "${w}/rom/stock.config"
verify() {
  (cd "${w}" && PATH="${tmp_dir}/bin:${PATH}" KERNEL_DIR=k CONFIG_DISABLE="${1:-}" bash scripts/verify-rom-compat.sh) > "${tmp_dir}/v.log" 2>&1
}

printf 'CONFIG_MODVERSIONS=y\nCONFIG_LTO_CLANG_THIN=y\nCONFIG_CLANG_VERSION=180103\nCONFIG_KSU=y\nCONFIG_KSU_SUSFS=y\n' > "${w}/k/out/.config"
verify || { cat "${tmp_dir}/v.log"; fail "toolchain/LTO/KSU-only differences must pass"; }
grep -q 'RESULT: compatible' "${w}/k/release/rom-compat.txt" || fail "compatible result not recorded"

printf 'CONFIG_MODVERSIONS=y\nCONFIG_LTO_CLANG_THIN=y\nCONFIG_MODULE_SIG_PROTECT=y\n' > "${w}/k/out/.config"
printf 'CONFIG_MODVERSIONS=y\nCONFIG_MODULE_SIG_PROTECT=y\n' > "${w}/rom/stock.config"
printf 'CONFIG_MODVERSIONS=y\n# CONFIG_MODULE_SIG_PROTECT is not set\n' > "${w}/k/out/.config"
verify MODULE_SIG_PROTECT || { cat "${tmp_dir}/v.log"; fail "a profile's deliberate config_disable must pass"; }

printf 'CONFIG_MODVERSIONS=n\n' > "${w}/k/out/.config"
if verify; then fail "an unexpected config difference must fail"; fi
grep -q 'CONFIG_MODVERSIONS' "${tmp_dir}/v.log" || fail "config difference not reported"

printf 'CONFIG_MODVERSIONS=y\nCONFIG_MODULE_SIG_PROTECT=y\n' > "${w}/k/out/.config"
sed -i 's/^rom_kernel_commit=.*/rom_kernel_commit=ffffffffffff/' "${w}/release/rom-target.env"
if verify; then fail "a different kernel commit must fail"; fi
grep -q 'NOT compatible' "${w}/k/release/rom-compat.txt" || fail "incompatible result not recorded"

echo "rom_target=none" > "${w}/release/rom-target.env"
verify || fail "rom_url=none must not fail the build"
grep -q 'not verified' "${w}/k/release/rom-compat.txt" || fail "unverified build not recorded"

# ── anykernel.sh check_kernel_series ──
sed -n '/^banner_release()/,/^check_kernel_series()/p' "${repo_root}/ak3/anykernel.sh" | sed '$d' > "${tmp_dir}/ak.sh"
sed -n '/^check_kernel_series()/,/^}/p' "${repo_root}/ak3/anykernel.sh" >> "${tmp_dir}/ak.sh"
mkdir -p "${tmp_dir}/ak/split"
banner() { printf 'x\0Linux version %s (b@h) (clang) #1 SMP\0' "$1" > "$2"; }
ak_run() { # new-release cur-release zipname -> exit status
  banner "$1" "${tmp_dir}/ak/Image"
  if [[ -n "$2" ]]; then banner "$2" "${tmp_dir}/ak/split/kernel"; else printf 'nothing' > "${tmp_dir}/ak/split/kernel"; fi
  sh -c "ui_print() { :; }; abort() { exit 9; }; uname() { echo ''; }
    AKHOME='${tmp_dir}/ak'; SPLITIMG='${tmp_dir}/ak/split'; ZIPFILE='/sdcard/$3'
    . '${tmp_dir}/ak.sh'; check_kernel_series"
}
ak_run 5.10.269-gki-g658b84f13496-dirty 5.10.269-gki-g658b84f13496 k.zip || fail "matching kernel refused"
# Refusals must come from abort (exit 9), not from some other error.
expect_abort() { local rc=0; ak_run "$@" || rc=$?; [[ ${rc} -eq 9 ]]; }
expect_abort 6.6.144-4k-g32cd81a28c49-dirty 5.10.269-gki-g658b84f13496 k.zip || fail "series mismatch not refused"
expect_abort 5.10.269-gki-gaaaaaaaaaaaa-dirty 5.10.269-gki-g658b84f13496 k.zip || fail "commit mismatch not refused"
expect_abort 5.10.269-gki-g658b84f13496-dirty "" k.zip || fail "unreadable ROM kernel not refused"
ak_run 6.6.144-4k-g32cd81a28c49-dirty 5.10.269-gki-g658b84f13496 k-force.zip || fail "force flash ignored"

echo "ROM compat tests passed"
