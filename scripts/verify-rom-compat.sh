#!/usr/bin/env bash
# After the build: prove the new kernel can run the target ROM (see
# resolve-target-rom.sh). Fails the build, so no zip is produced, when:
#   - the kernel series or source commit differs from the ROM kernel's,
#   - the kernel config differs from the ROM kernel's beyond toolchain/LTO
#     and root-manager/SUSFS options (and the profile's deliberate overrides),
#   - any ROM module would be rejected: missing export, CRC mismatch,
#     different struct module size or vermagic flags.
set -euo pipefail

source config/marble.env
KERNEL_DIR="${KERNEL_DIR:-kernel-source}"
ROM_DIR="${ROM_DIR:-rom}"
out="${KERNEL_DIR}/${OUT_DIR}"
report="${KERNEL_DIR}/${RELEASE_DIR}/rom-compat.txt"

# shellcheck disable=SC1091
source release/rom-target.env
if [[ "${rom_target:-none}" == "none" ]]; then
  echo "::warning::No target ROM: this zip was NOT verified against your ROM's kernel modules"
  echo "rom_target=none (not verified)" > "${report}"
  exit 0
fi

{
  echo "rom_target=${rom_target}"
  echo "rom_kernel=${rom_kernel_release}"
} > "${report}"
fail=0

our_release="$(python3 -I scripts/lib/rom_extract.py release "${out}/arch/arm64/boot/Image")"
our_series="$(sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p' <<<"${our_release}")"
our_commit="$(sed -n 's/^.*-g\([0-9a-f]\{12\}\).*$/\1/p' <<<"${our_release}")"
echo "our_kernel=${our_release}" >> "${report}"
if [[ "${our_series}" != "${rom_kernel_series}" ]]; then
  echo "::error::Kernel ${our_series} built, but ${rom_target} runs ${rom_kernel_series}"
  fail=1
elif [[ -z "${our_commit}" || "${our_commit}" != "${rom_kernel_commit}" ]]; then
  echo "::error::Kernel built from commit ${our_commit:-unknown}, but ${rom_target}'s kernel is ${rom_kernel_commit:-unknown}; leave source_ref empty to build the ROM's commit (the zip would refuse to flash otherwise)"
  fail=1
fi

# Config: only toolchain, LTO, root manager/SUSFS and the profile's own
# overrides may differ from the ROM kernel.
if [[ -s "${ROM_DIR}/stock.config" ]]; then
  ALLOWED="${CONFIG_ENABLE:-} ${CONFIG_DISABLE:-}" python3 -I - "${ROM_DIR}/stock.config" "${out}/.config" >> "${report}" <<'PY' || fail=1
import os, re, sys

def load(p):
    cfg = {}
    for line in open(p, encoding="utf-8", errors="replace"):
        m = re.match(r"^CONFIG_(\w+)=(.*)$", line)
        if m:
            cfg[m.group(1)] = m.group(2)
        m = re.match(r"^# CONFIG_(\w+) is not set$", line)
        if m:
            cfg[m.group(1)] = "n"
    return cfg

stock, ours = load(sys.argv[1]), load(sys.argv[2])
allowed = set(os.environ.get("ALLOWED", "").split())
ignore = re.compile(
    r"^(CC_VERSION_TEXT|CLANG_VERSION|GCC_VERSION|AS_VERSION|LD_VERSION|LLD_VERSION|RUSTC_VERSION|"
    r"PAHOLE_VERSION|BUILD_SALT|CC_CAN_LINK|CC_CAN_LINK_STATIC|UAPI_HEADER_TEST|"
    r"LTO_CLANG|LTO_CLANG_FULL|LTO_CLANG_THIN|LTO_NONE|"
    r"(CC|AS|LD|TOOLS)_HAS_\w+|TOOLS_SUPPORT_\w+|CC_IS_\w+|LD_IS_\w+|"
    r"KSU|KSU_\w+|KPM\w*)$")
diffs = []
for k in sorted(set(stock) | set(ours)):
    a, b = stock.get(k, "n"), ours.get(k, "n")
    if a != b and not ignore.match(k) and k not in allowed:
        diffs.append(f"  CONFIG_{k}: rom={a} ours={b}")
print(f"config differences (unexpected): {len(diffs)}")
print("\n".join(diffs))
if diffs:
    print("::error::Kernel config differs from the ROM kernel's:\n" + "\n".join(diffs), file=sys.stderr)
    sys.exit(1)
PY
else
  echo "config: ROM kernel has no embedded config (not compared)" >> "${report}"
fi

# Module ABI: every ROM module must load on this kernel.
symvers="${out}/vmlinux.symvers"
[[ -s "${symvers}" ]] || symvers="${out}/Module.symvers"
if [[ ! -s "${symvers}" ]]; then
  echo "::error::No vmlinux.symvers/Module.symvers in ${out}: cannot verify module CRCs"
  fail=1
elif ! python3 -I scripts/lib/rom_modcheck.py --vmlinux "${out}/vmlinux" --symvers "${symvers}" \
     --report "${report}.modules" "${ROM_DIR}/modules"; then
  echo "::error::Some of ${rom_target}'s kernel modules would not load on this kernel (see rom-compat.txt)"
  fail=1
fi
cat "${report}.modules" >> "${report}" 2>/dev/null || true
rm -f "${report}.modules"

if (( fail )); then
  echo "RESULT: NOT compatible with ${rom_target}" | tee -a "${report}"
  exit 1
fi
echo "RESULT: compatible with ${rom_target}" | tee -a "${report}"
