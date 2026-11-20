#!/usr/bin/env bash
# Download the selected manager's official app (APK) so the flashable zip can
# install it. Only official release APKs work: the kernel recognises its
# manager by signing key, so a self-built/debug APK would be rejected.
#
# Picks the newest release (pre-releases included, since kernels are built from
# the manager's branch head) that has an .apk asset, skipping debug/unsigned
# variants. Never fails the build: without an APK the zip still works and the
# user installs the app manually.
set -euo pipefail

MANAGER="${MANAGER:-none}"
KERNEL_DIR="${KERNEL_DIR:-kernel-source}"
source config/marble.env
release_dir="${KERNEL_DIR}/${RELEASE_DIR}"
mkdir -p "${release_dir}"
rm -f "${release_dir}/manager.apk" "${release_dir}/manager-apk.env"

if [[ "${MANAGER}" == "none" ]]; then
  echo "No manager selected; no APK to fetch"
  exit 0
fi

apk_repo="$(jq -r --arg m "${MANAGER}" '.[$m].apk_repo // empty' config/managers.json)"
package="$(jq -r --arg m "${MANAGER}" '.[$m].package // empty' config/managers.json)"
if [[ -z "${apk_repo}" || -z "${package}" ]]; then
  echo "::warning::No apk_repo/package configured for ${MANAGER}; the zip will not install the manager app"
  exit 0
fi

api_get() {
  if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
    gh api "$1"
  else
    curl -fsSL -H 'Accept: application/vnd.github+json' \
      ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} "https://api.github.com/$1"
  fi
}

if ! releases="$(api_get "repos/${apk_repo}/releases?per_page=20")"; then
  echo "::warning::Could not list ${apk_repo} releases; the zip will not install the manager app"
  exit 0
fi

selection="$(
  printf '%s' "${releases}" | python3 -c '
import json, re, sys
releases = json.load(sys.stdin)
bad = re.compile(r"debug|unsigned|spoof", re.I)
for rel in releases:
    if rel.get("draft"):
        continue
    apks = [a for a in rel.get("assets", []) if a["name"].lower().endswith(".apk") and not bad.search(a["name"])]
    if not apks:
        continue
    apks.sort(key=lambda a: (0 if re.search(r"release", a["name"], re.I) else 1, len(a["name"]), a["name"]))
    a = apks[0]
    print(rel["tag_name"], a["name"], a["browser_download_url"], sep="\t")
    break
'
)"
if [[ -z "${selection}" ]]; then
  echo "::warning::No release APK found in ${apk_repo}; the zip will not install the manager app"
  exit 0
fi
IFS=$'\t' read -r apk_tag apk_name apk_url <<<"${selection}"

echo "Fetching ${MANAGER} manager ${apk_tag}: ${apk_name}"
if ! curl -fsSL --retry 3 -o "${release_dir}/manager.apk" "${apk_url}"; then
  echo "::warning::Download of ${apk_url} failed; the zip will not install the manager app"
  rm -f "${release_dir}/manager.apk"
  exit 0
fi
if ! unzip -tq "${release_dir}/manager.apk" >/dev/null 2>&1 ||
   ! unzip -Z1 "${release_dir}/manager.apk" | grep -qx 'AndroidManifest.xml'; then
  echo "::warning::${apk_name} is not a valid APK; the zip will not install the manager app"
  rm -f "${release_dir}/manager.apk"
  exit 0
fi

apk_sha256="$(sha256sum "${release_dir}/manager.apk" | awk '{print $1}')"
{
  echo "manager_apk_repo=${apk_repo}"
  echo "manager_apk_tag=${apk_tag}"
  echo "manager_apk_name=${apk_name}"
  echo "manager_apk_sha256=${apk_sha256}"
  echo "manager_package=${package}"
} | tee "${release_dir}/manager-apk.env"
