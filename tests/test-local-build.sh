#!/usr/bin/env bash
# build.sh (local builder): selection, validation and the SUSFS/manager rules
# carried over from the workflow form, checked with --plan (nothing is built).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Run a copy so the user's saved choices (.marble-build.conf) are not touched.
cp -r "${repo_root}/build.sh" "${repo_root}/config" "${tmp_dir}/"
plan() { (cd "${tmp_dir}" && bash build.sh --plan "$@") 2>&1; }

bash "${tmp_dir}/build.sh" --help | grep -q -- '--susfs-version' || fail "--help lacks options"

out="$(plan --source all --manager bakasu,kernelsu-next --susfs --rom none)"
for s in melt lineageos evolution-x aosp-pablo pa-gr; do
  for m in bakasu kernelsu-next; do
    grep -q "^  ${s} + ${m} + SUSFS latest$" <<<"${out}" || fail "missing ${s} + ${m} + SUSFS in plan"
  done
done

out="$(plan --source evolution-x --manager none,bakasu --susfs --rom none)"
grep -q '^  evolution-x + none$' <<<"${out}" || fail "SUSFS must not apply to the no-root build"
grep -q '^  evolution-x + bakasu + SUSFS latest$' <<<"${out}" || fail "bakasu + SUSFS missing"

if plan --manager kernelsu --susfs --rom none >/dev/null; then fail "KernelSU + SUSFS must be rejected"; fi
if plan --source nope --rom none >/dev/null; then fail "unknown source accepted"; fi
if plan --manager nope --rom none >/dev/null; then fail "unknown manager accepted"; fi
if plan --susfs-version custom --rom none >/dev/null; then fail "custom SUSFS without --susfs-ref accepted"; fi
if plan --lto huge --rom none >/dev/null; then fail "bad --lto accepted"; fi
if plan --toolchain gcc --rom none >/dev/null; then fail "bad --toolchain accepted"; fi
if plan --bogus >/dev/null; then fail "unknown option accepted"; fi

out="$(plan --source evolution-x --manager bakasu --susfs --susfs-version v2.2.0 --toolchain llvm-22.1.8 --lto full --scope full --rom none)"
grep -q 'toolchain: llvm-22.1.8   LTO: full   scope: full' <<<"${out}" || fail "options not reflected in the plan"
[[ ! -e "${tmp_dir}/.marble-build.conf" ]] || fail "--plan must not save choices"

echo "Local build tests passed"
