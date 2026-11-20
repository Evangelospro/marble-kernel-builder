#!/usr/bin/env bash
# anykernel.sh must retire another root manager's /data/adb userspace when the
# flashed kernel carries a different fork: the kernel's blocking
# `exec /data/adb/ksud post-fs-data` would otherwise run a foreign ksud and can
# hang boot (e.g. ReSukiSU kernel over a ROM with built-in KernelSU-Next).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

adb="${tmp_dir}/data/adb"
mkdir -p "${tmp_dir}/ak" "${adb}/ksu/bin" "${adb}/modules/modA" "${adb}/modules/modB"
touch "${adb}/ksud" "${adb}/modules/modB/disable"
echo resukisu > "${tmp_dir}/ak/marble-manager"

sed -n '/^prepare_manager_userspace()/,/^}/p' "${repo_root}/ak3/anykernel.sh" |
  sed "s|adb_dir=/data/adb;|adb_dir=${adb};|" > "${tmp_dir}/fn.sh"
grep -q "adb_dir=${adb};" "${tmp_dir}/fn.sh" || fail "could not extract prepare_manager_userspace"

run() {
  sh -c "ui_print() { :; }; AKHOME='${tmp_dir}/ak'; . '${tmp_dir}/fn.sh'; prepare_manager_userspace"
}

# First flash over the ROM's built-in manager (no marker yet).
run
[[ ! -e "${adb}/ksud" ]] || fail "foreign ksud was left in place"
[[ ! -e "${adb}/ksu" ]] || fail "foreign /data/adb/ksu was left in place"
backup="$(find "${adb}/marble-backup" -mindepth 1 -maxdepth 1 -type d)"
[[ -e "${backup}/ksud" && -d "${backup}/ksu" ]] || fail "old userspace not backed up"
[[ -e "${adb}/modules/modA/disable" ]] || fail "enabled module not disabled for first boot"
[[ "$(cat "${backup}/disabled-modules.txt")" == "modA" ]] || fail "disabled-modules list wrong"
[[ "$(cat "${adb}/.marble-manager")" == "resukisu" ]] || fail "marker not written"

# Reflashing the same manager must not touch the (new) userspace.
touch "${adb}/ksud"
run
[[ -e "${adb}/ksud" ]] || fail "same-manager reflash removed ksud"
[[ "$(find "${adb}/marble-backup" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]] ||
  fail "same-manager reflash created another backup"

echo "AK3 manager switch tests passed"
