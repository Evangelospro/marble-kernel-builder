#!/usr/bin/env bash
# Turn a phone dump (tools/dump-rom-from-phone.sh) into a committed ROM profile
# that "Resolve target ROM" / verify-rom-compat.sh use:
#
#   scripts/make-rom-profile.sh <dump-dir> <rom-file-name>
#   -> rom-profiles/<rom-file-name>/{profile.json.gz,stock.config.gz,rom.env}
#
# Then build with rom_url set to that same file name (any URL ending in it, or
# just the name): the download fails and the committed profile is used.
set -euo pipefail

dump="${1:?dump dir}"
rom="${2:?ROM file name, e.g. EvolutionX-17.0-20261117-marble-12.4-Official.zip}"
dest="rom-profiles/${rom}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

release="$(tr -d '\r\n' < "${dump}/uname-r.txt")"
mkdir -p "${work}/modules"

# Kernel config: /proc/config.gz, else the boot image's embedded config.
if [[ -s "${dump}/config.gz" ]]; then
  gzip -dc "${dump}/config.gz" > "${work}/stock.config"
elif [[ -s "${dump}/boot.img" ]]; then
  python3 -I scripts/lib/rom_extract.py kernel "${dump}/boot.img" "${work}/kernel"
  python3 -I scripts/lib/rom_extract.py ikconfig "${work}/kernel" "${work}/stock.config"
else
  echo "error: no config.gz or boot.img in ${dump}" >&2
  exit 1
fi
if [[ -s "${dump}/boot.img" ]]; then
  python3 -I scripts/lib/rom_extract.py kernel "${dump}/boot.img" "${work}/kernel"
  boot_release="$(python3 -I scripts/lib/rom_extract.py release "${work}/kernel")"
  if [[ -n "${boot_release}" && "${boot_release}" != "${release}" ]]; then
    echo "error: boot slot kernel ${boot_release} != running kernel ${release}" >&2
    exit 1
  fi
fi

complete=no
if [[ -s "${dump}/vendor_boot.img" ]]; then
  python3 -I scripts/lib/rom_extract.py vendor-ramdisks "${dump}/vendor_boot.img" "${work}/modules/vendor_boot"
  complete=yes
fi
for d in "${dump}"/vendor_dlkm_lib_modules "${dump}"/system_dlkm_lib_modules "${dump}"/vendor_lib_modules; do
  [[ -d "${d}" ]] && cp -r "${d}" "${work}/modules/"
done
count="$(find "${work}/modules" -name '*.ko' | wc -l)"
(( count > 0 )) || { echo "error: no kernel modules in ${dump}" >&2; exit 1; }

mkdir -p "${dest}"
python3 -I scripts/lib/rom_modcheck.py --dump-profile "${work}/profile.json" "${work}/modules"
gzip -9 -n -c "${work}/profile.json" > "${dest}/profile.json.gz"
gzip -9 -n -c "${work}/stock.config" > "${dest}/stock.config.gz"
{
  echo "rom_kernel_release=${release}"
  echo "rom_kernel_series=$(sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p' <<<"${release}")"
  echo "rom_kernel_commit=$(sed -n 's/^.*-g\([0-9a-f]\{12\}\).*$/\1/p' <<<"${release}")"
  echo "rom_module_count=${count}"
  echo "rom_profile_source=phone dump (first-stage vendor_boot modules included: ${complete})"
} > "${dest}/rom.env"
cat "${dest}/rom.env"
