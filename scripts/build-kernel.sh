#!/usr/bin/env bash
set -euo pipefail

# The preset's DEFCONFIG (from resolve-kernel-source.sh) must win over the
# Melt default in config/marble.env.
_caller_defconfig="${DEFCONFIG:-}"
source config/marble.env
DEFCONFIG="${_caller_defconfig:-${DEFCONFIG}}"

KERNEL_DIR="${KERNEL_DIR:-kernel-source}"
BUILD_SCOPE="${BUILD_SCOPE:-image-only}"
MANAGER="${MANAGER:-none}"
ENABLE_SUSFS="${ENABLE_SUSFS:-false}"
JOBS="${JOBS:-$(nproc)}"
USE_CCACHE="${USE_CCACHE:-true}"
TOOLCHAIN="${TOOLCHAIN:-android-r416183b}"

LTO="${LTO:-thin}"

# Memory-aware parallelism: about one compile/ThinLTO job per 3 GiB of RAM
# (GKI + clang LTO peaks around that per job), never more than the CPUs.
# 7 GiB runners -> 2 jobs, 16 GiB runners -> 4 (= all cores). Swap covers peaks.
# Self-hosted override: JOBS_FORCE=1 JOBS=8 THINLTO_JOBS=8
mem_gib="$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 }' /proc/meminfo 2>/dev/null || echo 0)"
mem_jobs=$(( mem_gib / 3 ))
(( mem_jobs >= 1 )) || mem_jobs=1
if [[ -z "${JOBS_FORCE:-}" ]] && (( JOBS > mem_jobs )); then
  echo "Capping JOBS from ${JOBS} to ${mem_jobs} (${mem_gib} GiB RAM)"
  JOBS="${mem_jobs}"
fi
THINLTO_JOBS="${THINLTO_JOBS:-${JOBS}}"

pushd "${KERNEL_DIR}" >/dev/null
mkdir -p "${OUT_DIR}" "${RELEASE_DIR}"

# ThinLTO: route the linker through a wrapper that caps codegen jobs and uses a
# persistent cache dir (restored/saved by the workflow). It must be passed on
# the make command line: the kernel Makefile assigns `LD = ld.lld` for LLVM=1,
# which overrides an exported LD (the old approach, so the cache stayed empty).
# The appended --thinlto-cache-dir also wins over the in-tree one some trees
# set under out/ (lld takes the last value).
make_ld_args=()
if [[ "${LTO}" == "thin" ]]; then
  THINLTO_CACHE_DIR="${THINLTO_CACHE_DIR:-${HOME}/.cache/thinlto}"
  mkdir -p "${THINLTO_CACHE_DIR}"
  wrapper="$(pwd)/${RELEASE_DIR}/ld-thinlto-wrapper"
  {
    printf '#!/bin/bash\n'
    # LLVM prunes by access time, which is unreliable after a cache restore,
    # so bound the cache by size (keeps restore/upload of it cheap).
    printf 'exec ld.lld "$@" --thinlto-jobs=%s --thinlto-cache-dir=%q --thinlto-cache-policy=cache_size_bytes=2g\n' \
      "${THINLTO_JOBS}" "${THINLTO_CACHE_DIR}"
  } > "${wrapper}"
  chmod +x "${wrapper}"
  make_ld_args=(LD="${wrapper}")
fi

# The build profile was chosen for KERNEL_VERSION; make sure the checked-out
# tree really is that version (a wrong-version profile bootloops).
tree_version="$(sed -n 's/^VERSION *= *//p' Makefile | head -n1).$(sed -n 's/^PATCHLEVEL *= *//p' Makefile | head -n1)"
if [[ -n "${KERNEL_VERSION:-}" && "${tree_version}" != "${KERNEL_VERSION}" ]]; then
  echo "::error::Checked-out tree is kernel ${tree_version}, but the build profile is for ${KERNEL_VERSION}"
  exit 1
fi
echo "Kernel tree version: ${tree_version}"

export ARCH
export SUBARCH="${ARCH}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-marble}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-github-actions}"
export CCACHE_DIR="${CCACHE_DIR:-${HOME}/.ccache}"
export CCACHE_COMPILERCHECK=content
export CCACHE_NOHASHDIR=true

if [[ -n "${ANDROID_CLANG_BIN:-}" ]]; then
  if [[ ! -x "${ANDROID_CLANG_BIN}/clang" ]]; then
    echo "::error::ANDROID_CLANG_BIN does not contain clang: ${ANDROID_CLANG_BIN}"
    exit 1
  fi
  export PATH="${ANDROID_CLANG_BIN}:${PATH}"
fi

if [[ "${USE_CCACHE}" == "true" ]] && command -v ccache >/dev/null 2>&1; then
  export CC="ccache clang"
  # LLVM 22 + LOS trees are heavier; allow a larger object cache when that toolchain is selected.
  if [[ "${TOOLCHAIN}" == "llvm-22.1.8" || "${TOOLCHAIN}" == "clang-18" ]]; then
    ccache -M 6G
  else
    ccache -M 4G
  fi
  ccache -o compression=true
  # compression_level is supported on modern ccache; ignore if unavailable.
  ccache -o compression_level=6 2>/dev/null || true
  ccache -z || true
else
  export CC="clang"
fi

clang --version | tee "${RELEASE_DIR}/build.log"

# Same variables for every make call (config and build), so Kconfig sees the
# same LD as the build.
make_args=(O="${OUT_DIR}" ARCH="${ARCH}" LLVM=1 LLVM_IAS=1 CC="${CC}" "${make_ld_args[@]}")

DEFCONFIG_MODE="${DEFCONFIG_MODE:-single}"
case "${DEFCONFIG_MODE}" in
  single)
    active_defconfig="${DEFCONFIG:-marble_defconfig}"
    echo "Using single defconfig: ${active_defconfig}" | tee -a "${RELEASE_DIR}/build.log"
    make "${make_args[@]}" "${active_defconfig}" 2>&1 | tee -a "${RELEASE_DIR}/build.log"
    ;;
  gki_fragments)
    base_defconfig="${BASE_DEFCONFIG:-gki_defconfig}"
    echo "Using GKI base defconfig: ${base_defconfig}" | tee -a "${RELEASE_DIR}/build.log"
    make "${make_args[@]}" "${base_defconfig}" 2>&1 | tee -a "${RELEASE_DIR}/build.log"

    if [[ -z "${CONFIG_FRAGMENTS:-}" ]]; then
      echo "::error::DEFCONFIG_MODE=gki_fragments requires CONFIG_FRAGMENTS"
      exit 1
    fi

    fragment_paths=()
    # shellcheck disable=SC2206
    fragment_list=(${CONFIG_FRAGMENTS})
    for fragment in "${fragment_list[@]}"; do
      fragment_path="arch/${ARCH}/configs/${fragment}"
      if [[ ! -f "${fragment_path}" ]]; then
        echo "::error::Missing config fragment: ${fragment_path}"
        exit 1
      fi
      fragment_paths+=("${fragment_path}")
      echo "  + fragment ${fragment_path}" | tee -a "${RELEASE_DIR}/build.log"
    done

    if [[ ! -x scripts/kconfig/merge_config.sh ]]; then
      echo "::error::scripts/kconfig/merge_config.sh is missing or not executable"
      exit 1
    fi
    ./scripts/kconfig/merge_config.sh -O "${OUT_DIR}" -m "${OUT_DIR}/.config" "${fragment_paths[@]}" 2>&1 | tee -a "${RELEASE_DIR}/build.log"
    ;;
  *)
    echo "::error::Unsupported DEFCONFIG_MODE: ${DEFCONFIG_MODE}"
    exit 1
    ;;
esac

if [[ "${MANAGER}" != "none" ]]; then
  scripts/config --file "${OUT_DIR}/.config" -e KSU
else
  # Trees with an in-tree KernelSU (Kconfig `default y`) would otherwise ship
  # root in a build labelled "noroot".
  scripts/config --file "${OUT_DIR}/.config" -d KSU
fi
if [[ "${ENABLE_SUSFS}" == "true" ]]; then
  scripts/config --file "${OUT_DIR}/.config" -e KSU_SUSFS
fi

# Apply selectable Clang LTO for all presets (including gki_fragments / Melt).
# Default thin is free-runner safe with swap + thinlto job caps; full needs more RAM.
echo "Applying LTO mode: ${LTO}" | tee -a "${RELEASE_DIR}/build.log"
case "${LTO}" in
  none)
    scripts/config --file "${OUT_DIR}/.config" \
      -d LTO_CLANG -d LTO_CLANG_THIN -d LTO_CLANG_FULL -e LTO_NONE || true
    # Also clear common Android synonyms if present
    scripts/config --file "${OUT_DIR}/.config" -e LTO_CLANG_NONE 2>/dev/null || true
    ;;
  thin)
    scripts/config --file "${OUT_DIR}/.config" \
      -d LTO_NONE -d LTO_CLANG_NONE -d LTO_CLANG_FULL -e LTO_CLANG -e LTO_CLANG_THIN || true
    ;;
  full)
    scripts/config --file "${OUT_DIR}/.config" \
      -d LTO_NONE -d LTO_CLANG_NONE -d LTO_CLANG_THIN -e LTO_CLANG -e LTO_CLANG_FULL || true
    echo "::warning::LTO=full is memory-heavy on free GitHub runners; prefer thin unless on high-RAM hosts"
    ;;
  *)
    echo "::error::Unsupported LTO=${LTO}"
    exit 1
    ;;
esac

# Preset-specific overrides (e.g. GKI 6.6 module-loading compatibility, see
# config/kernel-sources.json notes). Only options that do not change the KMI.
# shellcheck disable=SC2206
config_enable_list=(${CONFIG_ENABLE:-})
# shellcheck disable=SC2206
config_disable_list=(${CONFIG_DISABLE:-})
# shellcheck disable=SC2206
config_require_list=(${CONFIG_REQUIRE:-})
for opt in "${config_enable_list[@]}"; do
  echo "Preset config: enable ${opt}" | tee -a "${RELEASE_DIR}/build.log"
  scripts/config --file "${OUT_DIR}/.config" -e "${opt}"
done
for opt in "${config_disable_list[@]}"; do
  echo "Preset config: disable ${opt}" | tee -a "${RELEASE_DIR}/build.log"
  scripts/config --file "${OUT_DIR}/.config" -d "${opt}"
done

make "${make_args[@]}" olddefconfig 2>&1 | tee -a "${RELEASE_DIR}/build.log"

config_errors=0
for opt in "${config_enable_list[@]}" "${config_require_list[@]}"; do
  if ! grep -q "^CONFIG_${opt}=y$" "${OUT_DIR}/.config"; then
    echo "::error::CONFIG_${opt} must be =y in the final kernel config but is not."
    config_errors=1
  fi
done
for opt in "${config_disable_list[@]}"; do
  if grep -q "^CONFIG_${opt}=y$" "${OUT_DIR}/.config"; then
    echo "::error::CONFIG_${opt} must be disabled in the final kernel config but is still =y."
    config_errors=1
  fi
done
if (( config_errors )); then
  echo "::error::Kernel config does not match what the ROM's vendor modules expect; the Image would bootloop. (DEBUG_INFO_BTF* need pahole >= 1.21 from the dwarves package.)"
  exit 1
fi

if [[ "${MANAGER}" == "none" ]] && grep -q '^CONFIG_KSU=y$' "${OUT_DIR}/.config"; then
  echo "::error::CONFIG_KSU is still enabled in a no-root build"
  exit 1
fi
if [[ "${MANAGER}" != "none" ]] && ! grep -q '^CONFIG_KSU=y$' "${OUT_DIR}/.config"; then
  echo "::error::CONFIG_KSU is not enabled in the final kernel config"
  exit 1
fi
if [[ "${ENABLE_SUSFS}" == "true" ]] && ! grep -q '^CONFIG_KSU_SUSFS=y$' "${OUT_DIR}/.config"; then
  echo "::error::CONFIG_KSU_SUSFS is not enabled in the final kernel config"
  exit 1
fi

targets=(Image)
if [[ "${BUILD_SCOPE}" == "full" ]]; then
  targets+=(modules dtbs)
fi

echo "Build jobs=${JOBS}${make_ld_args:+, ThinLTO jobs=${THINLTO_JOBS} cache=${THINLTO_CACHE_DIR}}" | tee -a "${RELEASE_DIR}/build.log"
make -j"${JOBS}" "${make_args[@]}" "${targets[@]}" 2>&1 | tee -a "${RELEASE_DIR}/build.log"

image_path="${OUT_DIR}/arch/arm64/boot/Image"
if [[ ! -s "${image_path}" ]]; then
  echo "::error::Built Image not found at ${image_path}"
  exit 1
fi

image_size="$(stat -c%s "${image_path}")"
if [[ "${image_size}" -lt 5000000 ]]; then
  echo "::error::Built Image is unexpectedly small: ${image_size} bytes"
  exit 1
fi

if command -v file >/dev/null 2>&1; then
  file "${image_path}" | tee -a "${RELEASE_DIR}/build.log"
fi

cp "${image_path}" "${RELEASE_DIR}/Image"
for file in System.map vmlinux; do
  if [[ -s "${OUT_DIR}/${file}" ]]; then
    cp "${OUT_DIR}/${file}" "${RELEASE_DIR}/${file}"
  fi
done

if [[ "${BUILD_SCOPE}" == "full" ]]; then
  if find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtb' -print -quit | grep -q .; then
    find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtb' -print0 | tar --null -T - -czf "${RELEASE_DIR}/dtbs.tar.gz"
  fi
  if find "${OUT_DIR}" -name '*.ko' -print -quit | grep -q .; then
    find "${OUT_DIR}" -name '*.ko' -print0 | tar --null -T - -czf "${RELEASE_DIR}/modules.tar.gz"
  fi
fi

if [[ "${USE_CCACHE}" == "true" ]] && command -v ccache >/dev/null 2>&1; then
  ccache -s | tee "${RELEASE_DIR}/ccache-stats.txt" || true
fi

popd >/dev/null
