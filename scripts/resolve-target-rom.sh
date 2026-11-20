#!/usr/bin/env bash
# Pick the ROM build this kernel must match, fetch only its kernel-related
# partitions (range requests on the OTA zip, ~40 MiB instead of GBs), and:
#   - record the ROM kernel's release/commit and embedded config,
#   - unpack every kernel module the ROM ships (vendor_boot ramdisks,
#     vendor_dlkm, system_dlkm) for verify-rom-compat.sh,
#   - unless source_ref was given, build exactly the ROM kernel's commit.
#
# ROM selection: ROM_URL (workflow input rom_url) if set; "none" skips;
# otherwise the preset's official OTA feed (config/kernel-sources.json rom_ota).
#
# If the ROM host refuses the download (some CDNs block CI runners), a
# committed profile in rom-profiles/<rom file>/ is used instead: the same
# requirements (module imports/CRCs, struct module size, vermagic, kernel
# config and release) extracted earlier from that exact ROM.
set -euo pipefail

KERNEL_SOURCE="${KERNEL_SOURCE:-melt}"
ROM_URL="${ROM_URL:-}"
SOURCE_REF_INPUT="${SOURCE_REF_INPUT:-}"
ROM_DIR="${ROM_DIR:-rom}"
mkdir -p release
env_file=release/rom-target.env

skip() {
  echo "::warning::$1"
  echo "rom_target=none" > "${env_file}"
  exit 0
}

if [[ "${ROM_URL}" == "none" ]]; then
  skip "ROM verification disabled (rom_url=none): the zip is NOT checked against your ROM's modules"
fi

rom_file=""
if [[ -z "${ROM_URL}" ]]; then
  ota="$(jq -r --arg s "${KERNEL_SOURCE}" '.[$s].rom_ota // empty' config/kernel-sources.json)"
  if [[ -z "${ota}" ]]; then
    skip "No official ROM feed known for ${KERNEL_SOURCE} and no rom_url given: the zip is NOT checked against your ROM's modules"
  fi
  feed="$(curl -fsSL --retry 3 "${ota}")" || skip "Could not read ROM feed ${ota}"
  ROM_URL="$(jq -r '.response[0].download // empty' <<<"${feed}")"
  rom_file="$(jq -r '.response[0].filename // empty' <<<"${feed}")"
  [[ -n "${ROM_URL}" ]] || skip "ROM feed ${ota} has no download URL"
fi
[[ -n "${rom_file}" ]] || rom_file="$(basename "${ROM_URL%/download}")"
echo "Target ROM: ${rom_file}"
echo "  url: ${ROM_URL}"

rm -rf "${ROM_DIR}"
mkdir -p "${ROM_DIR}/img" "${ROM_DIR}/modules"
profile_dir="rom-profiles/${rom_file}"
if ! python3 -I scripts/lib/remote_payload.py "${ROM_URL}" "${ROM_DIR}/img" boot vendor_boot vendor_dlkm system_dlkm; then
  if [[ ! -s "${profile_dir}/profile.json.gz" ]]; then
    echo "::error::Could not download ${rom_file} and there is no committed profile in ${profile_dir}; cannot verify the kernel against your ROM (set rom_url to a reachable copy, or rom_url=none to build unverified)"
    exit 1
  fi
  echo "::notice::ROM download refused; using the committed profile of ${rom_file}"
  gzip -dc "${profile_dir}/profile.json.gz" > "${ROM_DIR}/profile.json"
  gzip -dc "${profile_dir}/stock.config.gz" > "${ROM_DIR}/stock.config"
  # shellcheck disable=SC1091
  source "${profile_dir}/rom.env"
  rom_release="${rom_kernel_release}"
  rom_series="${rom_kernel_series}"
  rom_commit="${rom_kernel_commit}"
  module_count="${rom_module_count}"
  echo "ROM kernel: ${rom_release} (profile)"
fi

if [[ ! -s "${ROM_DIR}/profile.json" ]]; then
  [[ -s "${ROM_DIR}/img/boot.img" ]] || { echo "::error::ROM has no boot partition in its payload"; exit 1; }
  python3 -I scripts/lib/rom_extract.py kernel "${ROM_DIR}/img/boot.img" "${ROM_DIR}/stock-kernel"
  rom_release="$(python3 -I scripts/lib/rom_extract.py release "${ROM_DIR}/stock-kernel")"
  python3 -I scripts/lib/rom_extract.py ikconfig "${ROM_DIR}/stock-kernel" "${ROM_DIR}/stock.config" ||
    echo "::warning::ROM kernel has no embedded config; config comparison skipped"
  rom_series="$(sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p' <<<"${rom_release}")"
  rom_commit="$(sed -n 's/^.*-g\([0-9a-f]\{12\}\).*$/\1/p' <<<"${rom_release}")"
  echo "ROM kernel: ${rom_release:-unknown}"

  if [[ -s "${ROM_DIR}/img/vendor_boot.img" ]]; then
    python3 -I scripts/lib/rom_extract.py vendor-ramdisks "${ROM_DIR}/img/vendor_boot.img" "${ROM_DIR}/modules/vendor_boot"
  fi
  for part in vendor_dlkm system_dlkm; do
    img="${ROM_DIR}/img/${part}.img"
    [[ -s "${img}" ]] || continue
    dest="${ROM_DIR}/modules/${part}"
    mkdir -p "${dest}"
    if debugfs -R 'stats' "${img}" >/dev/null 2>&1; then
      debugfs -R "rdump / ${dest}" "${img}" >/dev/null 2>&1
    elif command -v fsck.erofs >/dev/null 2>&1; then
      fsck.erofs --extract="${dest}" "${img}" >/dev/null
    else
      echo "::error::${part} is neither ext4 nor extractable erofs (install erofs-utils)"
      exit 1
    fi
  done
  module_count="$(find "${ROM_DIR}/modules" -name '*.ko' | wc -l)"
  echo "ROM kernel modules: ${module_count}"
  # Same requirements as a reusable profile (commit it to rom-profiles/<rom file>/
  # to keep verifying this ROM if its host later blocks CI downloads).
  python3 -I scripts/lib/rom_modcheck.py --dump-profile "${ROM_DIR}/profile.json" "${ROM_DIR}/modules"
fi

{
  echo "rom_target=${rom_file}"
  printf 'rom_url=%q\n' "${ROM_URL}"
  echo "rom_kernel_release=${rom_release}"
  echo "rom_kernel_series=${rom_series}"
  echo "rom_kernel_commit=${rom_commit}"
  echo "rom_module_count=${module_count}"
} > "${env_file}"

# Build exactly the ROM kernel's commit unless the user chose a ref.
if [[ -z "${SOURCE_REF_INPUT}" ]]; then
  if [[ -z "${rom_commit}" ]]; then
    echo "::error::Cannot read the ROM kernel's source commit from '${rom_release}'; set source_ref to the commit your ROM's kernel was built from"
    exit 1
  fi
  source_repo="$(jq -r --arg s "${KERNEL_SOURCE}" '.[$s].repo' config/kernel-sources.json)"
  if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
    full="$(gh api "repos/${source_repo}/commits/${rom_commit}" --jq .sha 2>/dev/null || true)"
  else
    full="$(curl -fsSL "https://api.github.com/repos/${source_repo}/commits/${rom_commit}" 2>/dev/null | jq -r '.sha // empty' || true)"
  fi
  if [[ ! "${full}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::The ROM's kernel commit ${rom_commit} is not in ${source_repo}; set source_ref to the matching commit (or rom_url=none to skip verification)"
    exit 1
  fi
  echo "Building the ROM's exact kernel commit ${full}"
  echo "rom_source_ref=${full}" >> "${env_file}"
  SOURCE_REF="${full}" bash scripts/resolve-kernel-source.sh
fi
