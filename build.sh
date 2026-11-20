#!/usr/bin/env bash
# Step functions are called through step "$@", which shellcheck cannot follow.
# shellcheck disable=SC2317
# Marble kernel — local builder.
#
# Builds AnyKernel3 zips on this PC with the same pipeline (and the same
# options) the GitHub Actions workflow had, plus: the ROM to match can be a ROM
# zip on disk. Run without options for an interactive menu (it remembers your
# last choices), or pass options:
#
#   ./build.sh --rom ~/Downloads/EvolutionX-17.0-20261117-marble-12.4-Official.zip
#   ./build.sh --source evolution-x --manager bakasu --susfs --rom <zip> --push
#   ./build.sh --help
#
# Outputs: out/<build>/  (zip, -check.zip dry-run copy, .sha256, ROM report)
# Caches:  .build/       (kernel sources, toolchains, ccache, ThinLTO)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${MARBLE_BUILD_ROOT:-${REPO}/.build}"
OUT_ROOT="${MARBLE_OUT:-${REPO}/out}"
CONF="${REPO}/.marble-build.conf"

ALL_SOURCES="$(jq -r 'keys_unsorted | join(" ")' "${REPO}/config/kernel-sources.json")"
ALL_MANAGERS="none kernelsu kernelsu-next sukisu-ultra bakasu"

# ── defaults (overridden by the last run's choices, then by options) ────────
SOURCES="evolution-x"
MANAGERS="bakasu"
SUSFS=true
SUSFS_VERSION=latest
SUSFS_REF=""
SOURCE_REF=""
MANAGER_REF=""
ROM=""
SCOPE=image-only
TOOLCHAIN=auto
LTO=thin
CCACHE=true
PUSH=false
JOBS=""
# shellcheck disable=SC1090
[[ -f "${CONF}" ]] && source "${CONF}"

usage() {
  cat <<EOF
Usage: ./build.sh [options]          (no options: interactive menu)

Selection (same as the old workflow form):
  --source LIST        kernel source(s), comma separated, or "all"
                       (${ALL_SOURCES// /, })               [${SOURCES}]
  --manager LIST       root manager(s), comma separated
                       (${ALL_MANAGERS// /, })              [${MANAGERS}]
  --susfs / --no-susfs SUSFS (KernelSU-Next, SukiSU Ultra, BakaSU)       [${SUSFS}]
  --susfs-version V    latest | v2.2.0 | v2.1.0 | custom                [${SUSFS_VERSION}]
  --susfs-ref REF      SUSFS branch/tag/commit (with --susfs-version custom)
  --rom ROM            ROM to build for and verify against:
                       path to the ROM zip (recommended), a URL, a name in
                       rom-profiles/, "" = official latest, none = skip  [${ROM:-official latest}]
  --source-ref REF     kernel branch/tag/commit (default: the ROM kernel's commit)
  --manager-ref REF    manager branch/tag/commit (default: preset)
  --scope S            image-only | full                                [${SCOPE}]
  --toolchain T        auto | android-r416183b | llvm-22.1.8 | clang-18 [${TOOLCHAIN}]
  --lto L              none | thin | full                               [${LTO}]
  --no-ccache          disable ccache
  --jobs N             parallel jobs (default: by CPUs and RAM)
  --push / --no-push   copy the zips to the phone's Download/ via adb    [${PUSH}]
  --plan               only show what would be built, then exit
  --menu               interactive menu even with options
  -y, --yes            do not ask for confirmation
EOF
}

die() { echo "error: $*" >&2; exit 1; }
# "-susfs" when $1 is true. Always succeeds: `x="$(false && ...)"` would make
# the assignment fail and stop the script under set -e.
susfs_suffix() { if "$1"; then echo "${2:--susfs}"; fi; }
csv() { tr ',' ' ' <<<"$1" | xargs; }

# ── options ──────────────────────────────────────────────────────────────────
MENU=false
YES=false
PLAN=false
[[ $# -eq 0 && -t 0 ]] && MENU=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCES="$(csv "$2")"; shift ;;
    --manager) MANAGERS="$(csv "$2")"; shift ;;
    --susfs) SUSFS=true ;;
    --no-susfs) SUSFS=false ;;
    --susfs-version) SUSFS_VERSION="$2"; shift ;;
    --susfs-ref) SUSFS_REF="$2"; shift ;;
    --rom) ROM="$2"; shift ;;
    --source-ref) SOURCE_REF="$2"; shift ;;
    --manager-ref) MANAGER_REF="$2"; shift ;;
    --scope) SCOPE="$2"; shift ;;
    --toolchain) TOOLCHAIN="$2"; shift ;;
    --lto) LTO="$2"; shift ;;
    --no-ccache) CCACHE=false ;;
    --ccache) CCACHE=true ;;
    --jobs) JOBS="$2"; shift ;;
    --push) PUSH=true ;;
    --no-push) PUSH=false ;;
    --menu) MENU=true ;;
    --plan) PLAN=true ;;
    -y|--yes) YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done

# ── interactive menu ─────────────────────────────────────────────────────────
pick_many() { # title, choices, current -> echo selection
  local title="$1" choices="$2" current="$3" i=1 c ans out=()
  local -a list
  read -r -a list <<<"${choices}"
  {
    echo
    echo "${title}"
    for c in "${list[@]}"; do printf '  %d) %s\n' "${i}" "${c}"; i=$((i + 1)); done
    printf 'Numbers or names, comma separated, "all" [%s]: ' "${current}"
  } >&2
  read -r ans
  [[ -z "${ans}" ]] && { echo "${current}"; return; }
  [[ "${ans}" == all ]] && { echo "${choices}"; return; }
  for c in $(csv "${ans}"); do
    if [[ "${c}" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#list[@]} )); then
      out+=("${list[c - 1]}")
    else
      out+=("${c}")
    fi
  done
  echo "${out[*]}"
}
ask() { # prompt, current -> echo answer
  local ans
  read -r -e -p "$1 [$2]: " ans
  echo "${ans:-$2}"
}
yesno() { # prompt, current(true/false)
  local d=n ans
  [[ "$2" == true ]] && d=y
  read -r -p "$1 (y/n) [${d}]: " ans
  ans="${ans:-${d}}"
  [[ "${ans}" =~ ^[Yy] ]] && echo true || echo false
}

if ${MENU}; then
  echo "Marble kernel — local build"
  SOURCES="$(pick_many "Kernel source:" "${ALL_SOURCES}" "${SOURCES}")"
  MANAGERS="$(pick_many "Root manager:" "${ALL_MANAGERS}" "${MANAGERS}")"
  SUSFS="$(yesno "Enable SUSFS?" "${SUSFS}")"
  if ${SUSFS}; then
    SUSFS_VERSION="$(ask "SUSFS version (latest, v2.2.0, v2.1.0, custom)" "${SUSFS_VERSION}")"
    [[ "${SUSFS_VERSION}" == custom ]] && SUSFS_REF="$(ask "SUSFS branch/tag/commit" "${SUSFS_REF}")"
  fi
  echo
  echo "ROM to build for: path to the ROM zip you flash (Tab completes paths),"
  echo "a URL, a name from rom-profiles/, empty = official latest, none = skip check."
  ROM="$(ask "ROM" "${ROM}")"
  PUSH="$(yesno "Copy the finished zip to the phone (adb)?" "${PUSH}")"
  if [[ "$(yesno "Advanced options (kernel ref, scope, toolchain, LTO, ccache)?" false)" == true ]]; then
    SOURCE_REF="$(ask "Kernel source ref (empty = ROM kernel's commit)" "${SOURCE_REF}")"
    MANAGER_REF="$(ask "Manager ref (empty = preset)" "${MANAGER_REF}")"
    SCOPE="$(ask "Build scope (image-only, full)" "${SCOPE}")"
    TOOLCHAIN="$(ask "Toolchain (auto, android-r416183b, llvm-22.1.8, clang-18)" "${TOOLCHAIN}")"
    LTO="$(ask "LTO (none, thin, full)" "${LTO}")"
    CCACHE="$(yesno "Use ccache?" "${CCACHE}")"
  fi
fi

# ── validate ─────────────────────────────────────────────────────────────────
[[ "${SOURCES}" == all ]] && SOURCES="${ALL_SOURCES}"
for s in ${SOURCES}; do [[ " ${ALL_SOURCES} " == *" ${s} "* ]] || die "unknown source ${s} (${ALL_SOURCES})"; done
for m in ${MANAGERS}; do [[ " ${ALL_MANAGERS} " == *" ${m} "* ]] || die "unknown manager ${m} (${ALL_MANAGERS})"; done
[[ -n "${SOURCES}" && -n "${MANAGERS}" ]] || die "select at least one source and one manager"
case "${SUSFS_VERSION}" in latest|v2.2.0|v2.1.0|custom) ;; *) die "bad --susfs-version ${SUSFS_VERSION}" ;; esac
[[ "${SUSFS_VERSION}" != custom || -n "${SUSFS_REF}" ]] || die "--susfs-version custom needs --susfs-ref"
case "${SCOPE}" in image-only|full) ;; *) die "bad --scope ${SCOPE}" ;; esac
case "${TOOLCHAIN}" in auto|android-r416183b|llvm-22.1.8|clang-18) ;; *) die "bad --toolchain ${TOOLCHAIN}" ;; esac
case "${LTO}" in none|thin|full) ;; *) die "bad --lto ${LTO}" ;; esac
if [[ -n "${ROM}" && "${ROM}" != none ]]; then
  ROM="${ROM/#\~/${HOME}}"
  [[ -f "${ROM}" ]] && ROM="$(cd "$(dirname "${ROM}")" && pwd)/$(basename "${ROM}")"
fi

# Same SUSFS rule as the workflow matrix: SUSFS applies to managers with a
# SUSFS-capable ref; KernelSU cannot be combined with SUSFS.
combos=()
for s in ${SOURCES}; do
  for m in ${MANAGERS}; do
    susfs=false
    if ${SUSFS} && [[ "${m}" != none ]]; then
      [[ -n "$(jq -r --arg m "${m}" '.[$m].susfs_ref // empty' "${REPO}/config/managers.json")" ]] ||
        die "${m} does not support SUSFS; drop it or use --no-susfs"
      susfs=true
    fi
    combos+=("${s}|${m}|${susfs}")
  done
done

echo
echo "Builds:"
for c in "${combos[@]}"; do IFS='|' read -r s m f <<<"${c}"; echo "  ${s} + ${m}$(susfs_suffix "${f}" " + SUSFS ${SUSFS_VERSION}")"; done
echo "ROM: ${ROM:-official latest}   toolchain: ${TOOLCHAIN}   LTO: ${LTO}   scope: ${SCOPE}"
${PLAN} && exit 0

# Remember these choices for the next run.
cat > "${CONF}" <<EOF
SOURCES="${SOURCES}"
MANAGERS="${MANAGERS}"
SUSFS=${SUSFS}
SUSFS_VERSION="${SUSFS_VERSION}"
SUSFS_REF="${SUSFS_REF}"
SOURCE_REF="${SOURCE_REF}"
MANAGER_REF="${MANAGER_REF}"
ROM="${ROM}"
SCOPE="${SCOPE}"
TOOLCHAIN="${TOOLCHAIN}"
LTO="${LTO}"
CCACHE=${CCACHE}
PUSH=${PUSH}
JOBS="${JOBS}"
EOF
if ! ${YES} && [[ -t 0 ]]; then
  read -r -p "Start? (Y/n) " a
  [[ -z "${a}" || "${a}" =~ ^[Yy] ]] || exit 0
fi

# ── host checks ──────────────────────────────────────────────────────────────
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die "needs Linux x86_64 (on Windows: WSL2)"
missing=()
for t in bc bison flex make gcc git curl jq python3 rsync zip unzip zstd lz4 cpio debugfs pahole file perl; do
  command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
done
[[ -f /usr/include/openssl/ssl.h ]] || missing+=("libssl-dev")
[[ -f /usr/include/gelf.h ]] || missing+=("libelf-dev")
${CCACHE} && { command -v ccache >/dev/null 2>&1 || missing+=("ccache"); }
${PUSH} && { command -v adb >/dev/null 2>&1 || missing+=("adb"); }
if (( ${#missing[@]} )); then
  echo "Missing tools: ${missing[*]}" >&2
  echo "On Debian/Ubuntu: sudo apt install bc bison flex build-essential git curl jq python3 rsync zip unzip zstd lz4 cpio e2fsprogs erofs-utils dwarves file perl libssl-dev libelf-dev ccache clang lld llvm adb" >&2
  exit 1
fi
mem_gib="$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 }' /proc/meminfo)"
swap_gib="$(awk '/^SwapTotal:/ { printf "%d", $2 / 1048576 }' /proc/meminfo)"
if [[ "${LTO}" != none ]] && (( mem_gib + swap_gib < 16 )); then
  echo "warning: ${mem_gib} GiB RAM + ${swap_gib} GiB swap; LTO links can need ~16 GiB. Add swap if the build gets killed." >&2
fi

# GitHub API: needed to download the exact official manager app build
# (artifacts need a login) and recommended against rate limits.
if [[ -z "${GH_TOKEN:-}" ]]; then
  GH_TOKEN="${GITHUB_TOKEN:-}"
  [[ -z "${GH_TOKEN}" ]] && command -v gh >/dev/null 2>&1 && GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
export GH_TOKEN
if [[ -z "${GH_TOKEN}" ]]; then
  for c in "${combos[@]}"; do
    IFS='|' read -r _ m _ <<<"${c}"
    if [[ -n "$(jq -r --arg m "${m}" '.[$m].apk_build // empty' "${REPO}/config/managers.json")" ]]; then
      die "${m} zips include the exact official ${m} app, which GitHub only lets logged-in users download: run 'gh auth login' once (or set GITHUB_TOKEN)"
    fi
  done
fi

mkdir -p "${BUILD_ROOT}/cache/src" "${BUILD_ROOT}/cache/toolchains" "${BUILD_ROOT}/work" "${OUT_ROOT}"
run_file="${BUILD_ROOT}/run-number"
run=$(( $(cat "${run_file}" 2>/dev/null || echo 0) + 1 ))
echo "${run}" > "${run_file}"

# ── helpers ──────────────────────────────────────────────────────────────────
# Steps leave their results in release/*.env (shell-quoted); load them so the
# next step sees e.g. the ROM kernel's commit and the resolved toolchain.
load_state() {
  local f
  set -a
  for f in release/kernel-source.env release/toolchain.env; do
    # shellcheck disable=SC1090
    [[ -s "${f}" ]] && source "${f}"
  done
  set +a
}
step() { # name, command...
  local name="$1"; shift
  echo
  echo "━━ ${name}"
  "$@"
  load_state
}

setup_toolchain() {
  # shellcheck disable=SC1091
  source config/marble.env
  local tc="${BUILD_ROOT}/cache/toolchains" bin version commit="" digest=""
  case "${TOOLCHAIN}" in
    llvm-22.1.8)
      bin="${tc}/llvm-22.1.8/bin"
      if [[ ! -x "${bin}/clang" ]]; then
        local archive="${tc}/LLVM-22.1.8-Linux-X64.tar.xz"
        curl --fail --location --retry 3 --output "${archive}" "${LLVM_22_1_8_URL}"
        echo "${LLVM_22_1_8_SHA256}  ${archive}" | sha256sum -c -
        rm -rf "${tc}/llvm-22.1.8"; mkdir -p "${tc}/llvm-22.1.8"
        tar -xJf "${archive}" -C "${tc}/llvm-22.1.8" --strip-components=1
        rm -f "${archive}"
      fi
      version="LLVM 22.1.8"; digest="${LLVM_22_1_8_SHA256}" ;;
    android-r416183b)
      bin="${tc}/android-clang/${ANDROID_CLANG_VERSION}/bin"
      if [[ ! -x "${bin}/clang" ]]; then
        local repo="${tc}/android-clang-repo"
        rm -rf "${repo}"
        git clone --filter=blob:none --no-checkout --depth=1 --branch "${ANDROID_CLANG_REF}" "${ANDROID_CLANG_REPO}" "${repo}"
        [[ "$(git -C "${repo}" rev-parse HEAD)" == "${ANDROID_CLANG_REF_COMMIT}" ]] ||
          die "Android Clang ref moved (expected ${ANDROID_CLANG_REF_COMMIT})"
        git -C "${repo}" sparse-checkout set "${ANDROID_CLANG_VERSION}"
        git -C "${repo}" checkout -q --detach "${ANDROID_CLANG_REF_COMMIT}"
        mkdir -p "${tc}/android-clang"
        mv "${repo}/${ANDROID_CLANG_VERSION}" "${tc}/android-clang/"
        rm -rf "${repo}"
      fi
      version="${ANDROID_CLANG_VERSION}"; commit="${ANDROID_CLANG_REF_COMMIT}" ;;
    clang-18)
      bin=/usr/lib/llvm-18/bin
      [[ -x "${bin}/clang" && -x "${bin}/ld.lld" ]] || die "clang-18 needs LLVM 18 in /usr/lib/llvm-18 (sudo apt install clang-18 lld-18 llvm-18)"
      version="$("${bin}/clang" --version | head -n1)" ;;
    *) die "unsupported toolchain ${TOOLCHAIN}" ;;
  esac
  "${bin}/clang" --version | head -n1
  export ANDROID_CLANG_BIN="${bin}" ACTIVE_TOOLCHAIN_ID="${TOOLCHAIN}" ACTIVE_TOOLCHAIN_VERSION="${version}" \
    ACTIVE_TOOLCHAIN_COMMIT="${commit}" ACTIVE_TOOLCHAIN_DIGEST="${digest}"
}

checkout_kernel() {
  # One shallow object store per source repo, one worktree per build.
  local cache="${BUILD_ROOT}/cache/src/${SOURCE_REPO//\//_}.git" commit
  [[ -d "${cache}" ]] || git init -q --bare "${cache}"
  git -C "${cache}" fetch -q --depth 1 "https://github.com/${SOURCE_REPO}.git" "${SOURCE_REF}"
  commit="$(git -C "${cache}" rev-parse FETCH_HEAD)"
  git -C "${cache}" worktree prune
  git -C "${cache}" worktree add -q --detach "${PWD}/kernel-source" "${commit}"
  echo "${SOURCE_REPO} @ ${SOURCE_REF} -> ${commit}"
}

write_build_info() {
  cp release/resolved-refs.env kernel-source/release/resolved-refs.env
  {
    echo "kernel_source=${KERNEL_SOURCE}"
    echo "kernel_source_display=${KERNEL_SOURCE_DISPLAY:-}"
    echo "kernel_source_author=${KERNEL_SOURCE_AUTHOR:-}"
    echo "rom_family=${ROM_FAMILY:-}"
    echo "rom_support=${ROM_SUPPORT:-}"
    echo "supported_rom_label=${SUPPORTED_ROM_LABEL:-}"
    echo "defconfig_mode=${DEFCONFIG_MODE:-}"
    echo "defconfig=${DEFCONFIG:-}"
    echo "base_defconfig=${BASE_DEFCONFIG:-}"
    echo "config_fragments=${CONFIG_FRAGMENTS:-}"
    echo "source_repo=${SOURCE_REPO}"
    echo "source_ref=${SOURCE_REF}"
    echo "source_commit=$(git -C kernel-source rev-parse HEAD)"
    echo "workflow_run=local build #${run} on $(hostname)"
    echo "android_clang_version=${ACTIVE_TOOLCHAIN_VERSION}"
    echo "android_clang_commit=${ACTIVE_TOOLCHAIN_COMMIT}"
    echo "toolchain=${TOOLCHAIN}"
    echo "toolchain_digest=${ACTIVE_TOOLCHAIN_DIGEST}"
    echo "lto=${LTO}"
    echo "package_family=${PACKAGE_FAMILY:-}"
    echo "quality_channel=local"
    cat kernel-source/release/resolved-refs.env
  } > kernel-source/release/build-info.txt
}

# Keep what was learned about a ROM zip, so later builds can use just its name.
save_rom_profile() {
  # shellcheck disable=SC1091
  source release/rom-target.env
  [[ "${rom_target:-none}" != none && -s rom/profile.json && -s rom/stock.config ]] || return 0
  local dest="${REPO}/rom-profiles/${rom_target}"
  [[ -s "${dest}/profile.json.gz" ]] && return 0
  mkdir -p "${dest}"
  gzip -9 -n -c rom/profile.json > "${dest}/profile.json.gz"
  gzip -9 -n -c rom/stock.config > "${dest}/stock.config.gz"
  grep -E '^rom_(kernel_release|kernel_series|kernel_commit|module_count)=' release/rom-target.env > "${dest}/rom.env"
  echo "Saved ROM profile: rom-profiles/${rom_target}/ (later: --rom ${rom_target})"
}

build_one() {
  local source="$1" manager="$2" susfs="$3"
  local label
  label="${source}-${manager}$(susfs_suffix "${susfs}")"
  local work="${BUILD_ROOT}/work/${label}"
  local cache_src

  # Fresh work dir with the builder's files (sources/caches are reused).
  if [[ -d "${work}" ]]; then
    for cache_src in "${BUILD_ROOT}"/cache/src/*.git; do
      if [[ -d "${cache_src}" ]]; then
        git -C "${cache_src}" worktree remove --force "${work}/kernel-source" 2>/dev/null || true
      fi
    done
    rm -rf -- "${work:?}"
  fi
  mkdir -p "${work}"
  for d in ak3 config patches rom-profiles scripts tools; do ln -s "${REPO}/${d}" "${work}/${d}"; done
  cd "${work}"

  # Not BUILD_NUMBER: Android's scripts/setlocalversion would append
  # "-ab<BUILD_NUMBER>" to the kernel release.
  unset GITHUB_ENV GITHUB_OUTPUT BUILD_NUMBER
  export MARBLE_BUILD_NUMBER="${run}"
  export KERNEL_SOURCE="${source}" SOURCE_REF="${SOURCE_REF}" MANAGER="${manager}" MANAGER_REF="${MANAGER_REF}"
  export ENABLE_SUSFS="${susfs}" SUSFS_VERSION="${SUSFS_VERSION}" SUSFS_KERNEL_BRANCH=gki-android12-5.10
  export SUSFS_REF="${SUSFS_REF}" SUSFS_EXPECTED_VERSION="" BUILD_SCOPE="${SCOPE}" KERNEL_DIR=kernel-source
  export USE_CCACHE="${CCACHE}" TOOLCHAIN="${TOOLCHAIN}" LTO="${LTO}"
  export CCACHE_DIR="${BUILD_ROOT}/cache/ccache" CCACHE_BASEDIR="${work}"
  export THINLTO_CACHE_DIR="${BUILD_ROOT}/cache/thinlto/${source}"
  [[ -n "${JOBS}" ]] && export JOBS JOBS_FORCE=1

  step "Resolve kernel source" bash scripts/resolve-kernel-source.sh
  step "Resolve target ROM" env ROM_URL="${ROM}" SOURCE_REF_INPUT="${SOURCE_REF}" bash scripts/resolve-target-rom.sh
  save_rom_profile
  step "Resolve toolchain" bash scripts/resolve-toolchain.sh
  step "Validate inputs" bash scripts/validate-inputs.sh
  step "Toolchain" setup_toolchain
  step "Checkout kernel source" checkout_kernel
  step "Kernel source patches" bash scripts/apply-kernel-source-patches.sh
  step "Resolve manager/SUSFS refs" bash scripts/resolve-refs.sh
  step "Apply manager" bash scripts/patch-manager.sh
  step "Read manager version" bash scripts/read-manager-version.sh
  step "Apply SUSFS" bash scripts/apply-susfs.sh
  step "Build kernel" bash scripts/build-kernel.sh
  step "Verify against the ROM" bash scripts/verify-rom-compat.sh
  step "Manager build metadata" bash scripts/read-manager-build-metadata.sh
  step "Fetch manager app" bash scripts/fetch-manager-apk.sh
  step "Package zip" bash scripts/package-anykernel.sh
  write_build_info
  step "Build info" bash scripts/write-build-info-json.sh
  step "Audit zip" bash scripts/audit-flashable-zip.sh
  bash scripts/generate-build-summary.sh > /dev/null

  # shellcheck disable=SC1091
  source kernel-source/release/zip-name.env
  local dest="${OUT_ROOT}/${label}" check
  rm -rf -- "${dest:?}"; mkdir -p "${dest}"
  cp kernel-source/release/"${zip_name}" kernel-source/release/"${zip_name}".sha256 "${dest}/"
  check="${zip_name%.zip}-check.zip"
  cp kernel-source/release/"${zip_name}" "${dest}/${check}"
  for f in rom-compat.txt build-info.txt build-info.json summary.md; do
    [[ -f "kernel-source/release/${f}" ]] && cp "kernel-source/release/${f}" "${dest}/"
  done
  if ${PUSH}; then
    adb push "${dest}/${zip_name}" "${dest}/${check}" /sdcard/Download/ >/dev/null &&
      echo "Copied to the phone: Download/${zip_name} and Download/${check}"
  fi
}

RESULTS=()
for c in "${combos[@]}"; do
  IFS='|' read -r s m f <<<"${c}"
  echo
  echo "════════ ${s} + ${m}$(susfs_suffix "${f}" ' + SUSFS') ════════"
  # Not "if ( ... )": bash ignores set -e inside a condition, so a failing
  # step would not stop the build. Run it as a plain subshell instead.
  set +e
  ( set -e; build_one "${s}" "${m}" "${f}" )
  rc=$?
  set -e
  if (( rc == 0 )); then
    zipf=""
    for z in "${OUT_ROOT}/${s}-${m}$(susfs_suffix "${f}")"/*.zip; do
      [[ "${z}" == *-check.zip ]] || zipf="${z}"
    done
    RESULTS+=("OK    ${s} + ${m}$(susfs_suffix "${f}" ' + SUSFS'): ${zipf}")
  else
    RESULTS+=("FAIL  ${s} + ${m}$(susfs_suffix "${f}" ' + SUSFS') (see the output above)")
  fi
done

echo
echo "════════ Results (build #${run}) ════════"
printf '%s\n' "${RESULTS[@]}"
echo
echo "Before flashing: flash the -check.zip copy first (dry run, writes nothing),"
echo "then the zip itself. Keep the boot backup it saves to /sdcard/marble-kernel-backup/."
for r in "${RESULTS[@]}"; do [[ "${r}" == FAIL* ]] && exit 1; done
exit 0
