#!/usr/bin/env bash
# Download the official manager app built from the *same commit* as the kernel
# (selected by resolve-manager-build.sh via resolve-refs.sh) and verify it:
#   - package name is the manager's,
#   - it carries an arm64 ksud,
#   - its versionCode equals the kernel's KernelSU version code.
# A mismatch fails the build: a wrong app/ksud on the phone is worse than none.
# With no exact official build available nothing is bundled (warning only).
set -euo pipefail

MANAGER="${MANAGER:-none}"
KERNEL_DIR="${KERNEL_DIR:-kernel-source}"
source config/marble.env
release_dir="${KERNEL_DIR}/${RELEASE_DIR}"
RESOLVED_REFS_FILE="${RESOLVED_REFS_FILE:-release/resolved-refs.env}"
mkdir -p "${release_dir}"
rm -f "${release_dir}/manager.apk" "${release_dir}/manager-apk.env"

if [[ "${MANAGER}" == "none" ]]; then
  echo "No manager selected; no app to fetch"
  exit 0
fi

# shellcheck disable=SC1090
source "${RESOLVED_REFS_FILE}"
package="$(jq -r --arg m "${MANAGER}" '.[$m].package // empty' config/managers.json)"

if [[ -z "${manager_apk_artifact_id:-}" ]]; then
  echo "::warning::No exact official ${MANAGER} app build for ${manager_commit:-?}; the zip will not bundle the app or ksud"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

echo "Downloading ${manager_apk_repo} artifact ${manager_apk_artifact_id} (run ${manager_apk_run_id}, commit ${manager_commit})"
download_ok=1
if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
  gh api "repos/${manager_apk_repo}/actions/artifacts/${manager_apk_artifact_id}/zip" > "${work}/artifact.zip" || download_ok=0
else
  curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
    "https://api.github.com/repos/${manager_apk_repo}/actions/artifacts/${manager_apk_artifact_id}/zip" -o "${work}/artifact.zip" || download_ok=0
fi
if (( ! download_ok )) || ! unzip -q -o "${work}/artifact.zip" -d "${work}/artifact"; then
  # Bundling nothing is safe; a mismatched app is not. Don't fail the kernel build.
  echo "::warning::Could not download ${manager_apk_repo} artifact ${manager_apk_artifact_id}; the zip will not bundle the app or ksud"
  exit 0
fi

kernel_code="${manager_build_version_code:-}"
if [[ ! "${kernel_code}" =~ ^[0-9]+$ ]]; then
  echo "::error::Kernel KernelSU version code unknown (read-manager-build-metadata); cannot verify the app matches"
  exit 1
fi

chosen=""
while IFS= read -r -d '' apk; do
  info="$(python3 -I scripts/lib/apk_manifest.py "${apk}" 2>/dev/null)" || continue
  apk_pkg="$(sed -n 's/^package=//p' <<<"${info}")"
  apk_code="$(sed -n 's/^versionCode=//p' <<<"${info}")"
  apk_name="$(sed -n 's/^versionName=//p' <<<"${info}")"
  echo "  $(basename "${apk}"): package=${apk_pkg} versionCode=${apk_code} versionName=${apk_name}"
  [[ "${apk_pkg}" == "${package}" ]] || continue
  unzip -Z1 "${apk}" | grep -qx 'lib/arm64-v8a/libksud.so' || continue
  if [[ "${apk_code}" != "${kernel_code}" ]]; then
    echo "::error::$(basename "${apk}") is versionCode ${apk_code} but the kernel's ${MANAGER} is ${kernel_code}: not the same build"
    exit 1
  fi
  chosen="${apk}"
  chosen_name="${apk_name}"
  break
done < <(find "${work}/artifact" -type f -name '*.apk' -print0 | sort -z)

if [[ -z "${chosen}" ]]; then
  echo "::error::Artifact ${manager_apk_artifact_id} has no ${package} APK with an arm64 ksud"
  exit 1
fi

cp "${chosen}" "${release_dir}/manager.apk"
{
  echo "manager_apk_repo=${manager_apk_repo}"
  echo "manager_apk_run_id=${manager_apk_run_id}"
  echo "manager_apk_commit=${manager_commit}"
  echo "manager_apk_name=$(basename "${chosen}")"
  echo "manager_apk_version_code=${kernel_code}"
  echo "manager_apk_version_name=${chosen_name}"
  echo "manager_apk_sha256=$(sha256sum "${release_dir}/manager.apk" | awk '{print $1}')"
  echo "manager_package=${package}"
} | tee "${release_dir}/manager-apk.env"
echo "Manager app matches the kernel exactly: ${package} versionCode ${kernel_code} from commit ${manager_commit}"
