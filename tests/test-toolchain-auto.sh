#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

# resolve-toolchain.sh writes release/kernel-source.env; don't leave it behind
# (a stale one changes package naming in later tests).
if [[ ! -e release ]]; then
  trap 'rm -rf "${repo_root}/release"' EXIT
fi

out="$(KERNEL_SOURCE=lineageos SOURCE_REF=test-ref SOURCE_KERNEL_VERSION=5.10 TOOLCHAIN=auto bash scripts/resolve-toolchain.sh)"
echo "${out}" | grep -q 'TOOLCHAIN=llvm-22.1.8' || {
  echo "FAIL: LOS auto should resolve to llvm-22.1.8 (got: ${out})" >&2
  exit 1
}

out="$(KERNEL_SOURCE=melt SOURCE_REF=test-ref SOURCE_KERNEL_VERSION=5.10 TOOLCHAIN=auto bash scripts/resolve-toolchain.sh)"
echo "${out}" | grep -Eq 'TOOLCHAIN=android-r416183b' || {
  echo "FAIL: melt auto should resolve to android-r416183b (got: ${out})" >&2
  exit 1
}

out="$(KERNEL_SOURCE=lineageos SOURCE_REF=test-ref SOURCE_KERNEL_VERSION=5.10 TOOLCHAIN=android-r416183b bash scripts/resolve-toolchain.sh)"
echo "${out}" | grep -q 'TOOLCHAIN=android-r416183b' || {
  echo "FAIL: explicit override should stick (got: ${out})" >&2
  exit 1
}

echo "Toolchain auto tests passed"
