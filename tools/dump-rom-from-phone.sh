#!/usr/bin/env bash
# Collect what the kernel must match from the ROM running on a phone (via adb),
# for builds of ROMs that cannot be downloaded (test/unofficial builds).
#
#   tools/dump-rom-from-phone.sh [out-dir]      (default: rom-dump)
#
# Needs USB debugging. Without root it saves the kernel release, /proc/config.gz
# and the vendor_dlkm/system_dlkm modules. With root (su) it also saves the boot
# and vendor_boot partitions: vendor_boot holds the first-stage modules, so root
# gives a complete check. Nothing on the phone is modified.
set -euo pipefail

out="${1:-rom-dump}"
mkdir -p "${out}"
adb get-state >/dev/null

sh_() { adb shell "$@" | tr -d '\r'; }

sh_ uname -r > "${out}/uname-r.txt"
sh_ cat /proc/version > "${out}/proc-version.txt"
for p in ro.build.version.incremental ro.build.date ro.build.fingerprint ro.evolution.version \
         ro.evolution.build.version ro.product.device ro.boot.slot_suffix; do
  printf '%s=%s\n' "${p}" "$(sh_ getprop "${p}")"
done > "${out}/props.txt"
adb exec-out cat /proc/config.gz > "${out}/config.gz" || rm -f "${out}/config.gz"

for d in /vendor_dlkm/lib/modules /system_dlkm/lib/modules /vendor/lib/modules; do
  if [ "$(sh_ "[ -d ${d} ] && echo yes")" = yes ]; then
    dest="${out}/$(echo "${d#/}" | tr / _)"
    mkdir -p "${dest}"
    adb pull "${d}/." "${dest}/" >/dev/null
    echo "pulled ${d}: $(find "${dest}" -name '*.ko' | wc -l) modules"
  fi
done

if [ "$(sh_ "su -c 'echo yes'" 2>/dev/null)" = yes ]; then
  slot="$(sh_ getprop ro.boot.slot_suffix)"
  for p in boot vendor_boot; do
    adb exec-out "su -c 'cat /dev/block/by-name/${p}${slot}'" > "${out}/${p}.img"
    echo "saved ${p}${slot}: $(wc -c < "${out}/${p}.img") bytes"
  done
else
  echo "No root: boot/vendor_boot not saved (first-stage modules will not be checked)."
fi

tar -czf "${out}.tar.gz" "${out}"
echo
echo "Kernel: $(cat "${out}/uname-r.txt")"
echo "Done: ${out}.tar.gz"
