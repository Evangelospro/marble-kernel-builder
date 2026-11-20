#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
PYTHON="${PYTHON:-python3}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "FAIL: expected to find '${needle}' in output" >&2
    echo "${haystack}" >&2
    exit 1
  fi
}

# Offline stubs for the two network calls resolve-kernel-source.sh makes:
#   git ls-remote --symref https://github.com/<repo>.git HEAD  -> default branch
#   curl .../raw.githubusercontent.com/<repo>/<ref>/Makefile    -> kernel version
stub_bin="${tmp_dir}/bin"
mkdir -p "${stub_bin}"
cat >"${stub_bin}/git" <<'STUB'
#!/usr/bin/env bash
url="${3:-}"
case "${url}" in
  *mohdakil2426/android_kernel_xiaomi_marble.git) b=melt-rebase ;;
  *LineageOS/android_kernel_xiaomi_sm8450.git) b=lineage-24.0 ;;
  *Evolution-X-Devices/kernel_xiaomi_sm8450.git) b=cnb-6.6 ;;
  *aosp-pablo/android_kernel_xiaomi_sm8450.git) b=17 ;;
  *pa-gr/android_kernel_xiaomi_sm8450.git) b=vauxite ;;
  *) echo "stub git: unexpected $*" >&2; exit 2 ;;
esac
printf 'ref: refs/heads/%s\tHEAD\n0000000000000000000000000000000000000000\tHEAD\n' "${b}"
STUB
cat >"${stub_bin}/curl" <<'STUB'
#!/usr/bin/env bash
url="${*: -1}"
case "${url}" in
  */cnb-6.6/Makefile|*/kernel-6.12-test/Makefile) ;;
  */Makefile) printf 'VERSION = 5\nPATCHLEVEL = 10\nSUBLEVEL = 269\n'; exit 0 ;;
  *) echo "stub curl: unexpected ${url}" >&2; exit 22 ;;
esac
case "${url}" in
  */cnb-6.6/Makefile) printf 'VERSION = 6\nPATCHLEVEL = 6\nSUBLEVEL = 144\n' ;;
  */kernel-6.12-test/Makefile) printf 'VERSION = 6\nPATCHLEVEL = 12\nSUBLEVEL = 1\n' ;;
esac
STUB
chmod +x "${stub_bin}/git" "${stub_bin}/curl"

mkdir -p "${tmp_dir}/config" "${tmp_dir}/scripts"
cp "${repo_root}/config/kernel-sources.json" "${tmp_dir}/config/"
cp "${repo_root}/scripts/resolve-kernel-source.sh" "${tmp_dir}/scripts/"

# resolve <preset> <source_ref> -> prints release/kernel-source.env
resolve() {
  (
    cd "${tmp_dir}"
    rm -rf release
    mkdir -p release
    PATH="${stub_bin}:${PATH}" KERNEL_SOURCE="$1" SOURCE_REF="$2" SOURCE_KERNEL_VERSION='' \
      SUSFS_KERNEL_BRANCH=gki-android12-5.10 PYTHON="${PYTHON}" \
      bash scripts/resolve-kernel-source.sh >/dev/null
    cat release/kernel-source.env
  )
}

# No preset pins a ref: an empty source_ref follows each repo's default branch.
if grep -q '"default_ref"' config/kernel-sources.json; then
  echo "FAIL: kernel-sources.json must not pin default_ref; empty source_ref uses the repo default branch" >&2
  exit 1
fi

# Melt (HyperOS)
out="$(resolve melt '')"
assert_contains "${out}" "SOURCE_REPO=mohdakil2426/android_kernel_xiaomi_marble"
assert_contains "${out}" "SOURCE_REF=melt-rebase"
assert_contains "${out}" "KERNEL_VERSION=5.10"
assert_contains "${out}" "DEFCONFIG_MODE=single"
assert_contains "${out}" "DEFCONFIG=marble_defconfig"
assert_contains "${out}" "SUPPORTED_ROM_LABEL=HyperOS"
assert_contains "${out}" "KERNEL_SOURCE_AUTHOR=Melt"
assert_contains "${out}" "SUSFS_KERNEL_BRANCH=gki-android12-5.10"

# LOS presets on 5.10 default branches use GKI + fragments
for preset_repo in \
  "lineageos|LineageOS/android_kernel_xiaomi_sm8450|lineage-24.0|LineageOS" \
  "aosp-pablo|aosp-pablo/android_kernel_xiaomi_sm8450|17|aosp-pablo" \
  "pa-gr|pa-gr/android_kernel_xiaomi_sm8450|vauxite|pa-gr"
do
  IFS='|' read -r preset repo ref author <<<"${preset_repo}"
  out="$(resolve "${preset}" '')"
  assert_contains "${out}" "SOURCE_REPO=${repo}"
  assert_contains "${out}" "SOURCE_REF=${ref}"
  assert_contains "${out}" "KERNEL_VERSION=5.10"
  assert_contains "${out}" "DEFCONFIG_MODE=gki_fragments"
  assert_contains "${out}" "BASE_DEFCONFIG=gki_defconfig"
  assert_contains "${out}" "vendor/marble_GKI.config"
  assert_contains "${out}" "KERNEL_SOURCE_AUTHOR=${author}"
  assert_contains "${out}" "ROM_FAMILY=los"
done

# Evolution-X default branch (cnb-6.6) is kernel 6.6: pure GKI Image (Kleaf
# mixed build), 6.6 SUSFS branch, module-loading compatibility overrides.
out="$(resolve evolution-x '')"
assert_contains "${out}" "SOURCE_REPO=Evolution-X-Devices/kernel_xiaomi_sm8450"
assert_contains "${out}" "SOURCE_REF=cnb-6.6"
assert_contains "${out}" "KERNEL_VERSION=6.6"
assert_contains "${out}" "DEFCONFIG_MODE=single"
assert_contains "${out}" "DEFCONFIG=gki_defconfig"
assert_contains "${out}" "SUSFS_KERNEL_BRANCH=gki-android15-6.6"
assert_contains "${out}" "CONFIG_DISABLE=MODULE_SIG_PROTECT"
assert_contains "${out}" "DEBUG_INFO_BTF_MODULES"
assert_contains "${out}" "MODULE_ALLOW_BTF_MISMATCH"
assert_contains "${out}" "PACKAGE_FAMILY=LOS"
if [[ "${out}" == *"CONFIG_FRAGMENTS=vendor"* ]]; then
  echo "FAIL: Evolution-X 6.6 must not apply vendor fragments to the GKI Image" >&2
  exit 1
fi

# Explicit source_ref on the legacy 5.10 branch picks the 5.10 profile.
out="$(resolve evolution-x cnb)"
assert_contains "${out}" "SOURCE_REF=cnb"
assert_contains "${out}" "KERNEL_VERSION=5.10"
assert_contains "${out}" "DEFCONFIG_MODE=gki_fragments"
assert_contains "${out}" "SUSFS_KERNEL_BRANCH=gki-android12-5.10"

# Optional source_ref override
out="$(resolve lineageos lineage-23.1)"
assert_contains "${out}" "SOURCE_REF=lineage-23.1"

# A kernel version without a build profile must fail instead of bootlooping.
if (resolve evolution-x kernel-6.12-test) >/dev/null 2>&1; then
  echo "FAIL: a kernel version without a build profile should be rejected" >&2
  exit 1
fi

# Unknown preset must fail
if (resolve not-a-real-preset '') >/dev/null 2>&1; then
  echo "FAIL: unknown kernel_source should be rejected" >&2
  exit 1
fi

# Package naming uses author/ROM labels
assert_name() {
  local expected="$1"
  shift
  local actual
  actual="$(env PACKAGE_NAME_ONLY=true GITHUB_RUN_NUMBER=9 "$@" bash scripts/package-anykernel.sh)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

assert_name \
  'AK3_marble_LOS_lineageos_ksunext-v3.2.0-code33203_susfs-v2.2.0_r9.zip' \
  KERNEL_SOURCE=lineageos ROM_FAMILY=los \
  MANAGER=kernelsu-next ENABLE_SUSFS=true \
  manager_build_version_name='v3.2.0' manager_build_version_code=33203 \
  susfs_reported_version=v2.2.0

assert_name \
  'AK3_marble_LOS_evolution-x_noroot_r9.zip' \
  KERNEL_SOURCE=evolution-x ROM_FAMILY=los \
  MANAGER=none ENABLE_SUSFS=false

assert_name \
  'AK3_marble_LOS_aosp-pablo_resukisu-v4.1.0-code34990_r9.zip' \
  KERNEL_SOURCE=aosp-pablo ROM_FAMILY=los \
  MANAGER=resukisu ENABLE_SUSFS=false \
  manager_build_version_name=v4.1.0 manager_build_version_code=34990

assert_name \
  'AK3_marble_LOS_pa-gr_ksunext-v3.2.0-code33203_susfs-v2.2.0_r9.zip' \
  KERNEL_SOURCE=pa-gr ROM_FAMILY=los \
  MANAGER=kernelsu-next ENABLE_SUSFS=true \
  manager_build_version_name='v3.2.0' manager_build_version_code=33203 \
  susfs_reported_version=v2.2.0

assert_name \
  'AK3_marble_LOS_evolution-x_sukisu-v4.0.0-code40000_susfs-v2.4.0_r9.zip' \
  KERNEL_SOURCE=evolution-x ROM_FAMILY=los \
  MANAGER=sukisu-ultra ENABLE_SUSFS=true \
  manager_build_version_name=v4.0.0 manager_build_version_code=40000 \
  susfs_reported_version=v2.4.0

echo "Kernel source preset tests passed"
