#!/usr/bin/env bash
# The bundled manager app/ksud must be the exact build of the kernel's manager
# commit:
#  - resolve-manager-build.sh picks the newest commit with an unexpired,
#    successful push (production-signed) official build artifact;
#  - fetch-manager-apk.sh downloads that artifact and fails the build when the
#    APK's versionCode differs from the kernel's KernelSU version code;
#  - forks / managers without official per-commit builds bundle nothing.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# ── apk_manifest.py against a real aapt2-compiled manifest ──
mkdir -p "${tmp_dir}/apk/lib/arm64-v8a"
cp "${repo_root}/tests/fixtures/AndroidManifest-io.appium.settings-220.xml" "${tmp_dir}/apk/AndroidManifest.xml"
echo elf > "${tmp_dir}/apk/lib/arm64-v8a/libksud.so"
(cd "${tmp_dir}/apk" && zip -q -r ../app.apk AndroidManifest.xml lib)
out="$(python3 -I "${repo_root}/scripts/lib/apk_manifest.py" "${tmp_dir}/app.apk")"
[[ "${out}" == *"package=io.appium.settings"* ]] || fail "manifest package: ${out}"
[[ "${out}" == *"versionCode=220"* ]] || fail "manifest versionCode: ${out}"
[[ "${out}" == *"versionName=9.2.3"* ]] || fail "manifest versionName: ${out}"

# ── sandbox with stubbed gh ──
work="${tmp_dir}/work"
mkdir -p "${work}/config" "${work}/scripts/lib" "${work}/release" "${tmp_dir}/bin"
cp "${repo_root}/config/marble.env" "${work}/config/"
cp "${repo_root}/scripts/resolve-manager-build.sh" "${repo_root}/scripts/fetch-manager-apk.sh" "${work}/scripts/"
cp "${repo_root}/scripts/lib/apk_manifest.py" "${work}/scripts/lib/"
# Point the resukisu package at the fixture app's package.
jq '.resukisu.package = "io.appium.settings"' "${repo_root}/config/managers.json" > "${work}/config/managers.json"

(cd "${tmp_dir}" && rm -rf art && mkdir art && cp app.apk art/ReSukiSU_v1_220-release.apk && cd art && zip -q ../artifact.zip ./*.apk)
cat > "${tmp_dir}/bin/gh" <<STUB
#!/bin/sh
[ "\$1" = api ] || exit 1
case "\$2" in
  */workflows/build-manager.yml/runs\?branch=main*)
    # newest run (head) has only an expired artifact; older one is usable
    echo '{"workflow_runs":[{"id":3,"head_sha":"cccccccccccccccccccccccccccccccccccccccc","created_at":"2026-11-20T09:00:00Z"},{"id":2,"head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","created_at":"2026-11-19T09:00:00Z"}]}' ;;
  */runs/3/artifacts*) echo '{"artifacts":[{"id":30,"name":"Manager-release","expired":true}]}' ;;
  */runs/2/artifacts*) echo '{"artifacts":[{"id":21,"name":"Manager-debug","expired":false},{"id":20,"name":"Manager-release","expired":false}]}' ;;
  */actions/artifacts/20/zip) cat "${tmp_dir}/artifact.zip" ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${tmp_dir}/bin/gh"

resolve() { # MANAGER MANAGER_REPO MANAGER_REF
  (cd "${work}" && PATH="${tmp_dir}/bin:${PATH}" GH_TOKEN=x MANAGER="$1" MANAGER_REPO="$2" MANAGER_REF="$3" \
    MANAGER_COMMIT=cccccccccccccccccccccccccccccccccccccccc bash scripts/resolve-manager-build.sh 2>/dev/null)
}

out="$(resolve resukisu ReSukiSU/ReSukiSU main)"
eval "${out}"
[[ "${manager_apk_artifact_id}" == 20 ]] || fail "should skip the expired newest build and pick artifact 20 (got: ${out})"
[[ "${manager_apk_commit}" == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]] || fail "kernel must use the commit of the official build"
[[ "${manager_apk_repo}" == Baka-SU/BakaSU ]] || fail "official build repo"

eval "$(resolve kernelsu-next pershoot/KernelSU-Next dev-susfs)"
[[ -z "${manager_apk_artifact_id}" ]] || fail "a SUSFS fork must not get an official app"
eval "$(resolve sukisu-ultra SukiSU-Ultra/SukiSU-Ultra builtin)"
[[ -z "${manager_apk_artifact_id}" ]] || fail "managers without a known official build must bundle nothing"

# ── fetch: matching version code is accepted ──
fetch() { # kernel_version_code
  cat > "${work}/release/resolved-refs.env" <<EOF
manager_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
manager_apk_repo=Baka-SU/BakaSU
manager_apk_artifact_id=20
manager_apk_run_id=2
manager_build_version_code=$1
EOF
  (cd "${work}" && PATH="${tmp_dir}/bin:${PATH}" GH_TOKEN=x MANAGER=resukisu KERNEL_DIR=k bash scripts/fetch-manager-apk.sh)
}
fetch 220 > "${tmp_dir}/fetch-ok.log" 2>&1 || { cat "${tmp_dir}/fetch-ok.log"; fail "matching build rejected"; }
[[ -s "${work}/k/release/manager.apk" ]] || fail "APK not saved"
grep -q '^manager_apk_version_code=220$' "${work}/k/release/manager-apk.env" || fail "version code not recorded"

# ── fetch: version mismatch fails the build ──
if fetch 221 > "${tmp_dir}/fetch-bad.log" 2>&1; then
  fail "a versionCode mismatch must fail the build"
fi
grep -q 'not the same build' "${tmp_dir}/fetch-bad.log" || fail "mismatch not explained"
[[ ! -e "${work}/k/release/manager.apk" ]] || fail "mismatched APK left behind"

# ── fetch: download failure bundles nothing but does not fail the build ──
sed -i 's|^  \*/actions/artifacts/20/zip) cat .*|  */actions/artifacts/20/zip) echo "HTTP 403" >\&2; exit 1 ;;|' "${tmp_dir}/bin/gh"
fetch 220 > "${tmp_dir}/fetch-403.log" 2>&1 || fail "download failure must not fail the build"
grep -q 'Could not download' "${tmp_dir}/fetch-403.log" || fail "download failure not reported"
[[ ! -e "${work}/k/release/manager.apk" ]] || fail "APK present after failed download"

echo "Manager exact build tests passed"
