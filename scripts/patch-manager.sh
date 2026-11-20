#!/usr/bin/env bash
set -euo pipefail

MANAGER="${MANAGER:-none}"
KERNEL_DIR="${KERNEL_DIR:-kernel-source}"

if [[ "${MANAGER}" == "none" ]]; then
  echo "No manager selected"
  exit 0
fi

source release/resolved-refs.env

if [[ -z "${manager_repo}" || -z "${manager_commit}" || -z "${manager_setup_path}" ]]; then
  echo "::error::Manager resolution missing repo, commit, or setup path"
  exit 1
fi

pushd "${KERNEL_DIR}" >/dev/null

# Some trees (e.g. Evolution-X cnb-6.6) vendor a KernelSU fork as a real
# directory at drivers/kernelsu. Every manager's setup.sh runs
# `ln -sf <manager>/kernel kernelsu` from drivers/, which then drops the link
# *inside* the in-tree copy: setup "succeeds" but the in-tree fork is what gets
# compiled, so the selected manager (and its SUSFS support) is silently ignored.
# Remove the in-tree copy so the selected manager's symlink takes its place. The
# existing drivers/Makefile and drivers/Kconfig hooks are kept: setup.sh reuses
# them as-is.
if [[ -d drivers/kernelsu && ! -L drivers/kernelsu ]]; then
  echo "Removing in-tree drivers/kernelsu so ${MANAGER} replaces it"
  if [[ -f drivers/kernelsu/Kconfig ]]; then
    head -n 3 drivers/kernelsu/Kconfig || true
  fi
  rm -r -- ./drivers/kernelsu
fi

setup_url="https://raw.githubusercontent.com/${manager_repo}/${manager_commit}/${manager_setup_path}"
echo "Applying ${MANAGER} from ${manager_repo}@${manager_commit}"
curl -fsSL "${setup_url}" -o /tmp/manager-setup.sh

bash /tmp/manager-setup.sh "${manager_commit}"

if [[ ! -L drivers/kernelsu ]]; then
  echo "::error::${MANAGER} setup did not create the drivers/kernelsu symlink; the build would not use the selected manager"
  ls -la drivers/kernelsu 2>&1 || true
  exit 1
fi
echo "drivers/kernelsu -> $(readlink drivers/kernelsu)"
popd >/dev/null
