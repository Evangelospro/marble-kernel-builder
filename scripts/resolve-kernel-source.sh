#!/usr/bin/env bash
set -euo pipefail

KERNEL_SOURCE="${KERNEL_SOURCE:-melt}"
# Optional override for branch/tag/commit. Empty means use the preset default.
SOURCE_REF="${SOURCE_REF:-}"

if [[ ! -f config/kernel-sources.json ]]; then
  echo "::error::config/kernel-sources.json is missing"
  exit 1
fi

PYTHON="${PYTHON:-python3}"
eval "$(
  KERNEL_SOURCE="${KERNEL_SOURCE}" SOURCE_REF="${SOURCE_REF}" "${PYTHON}" - config/kernel-sources.json <<'PY'
import json
import os
import shlex
import sys

config_path = sys.argv[1]
kernel_source = os.environ.get("KERNEL_SOURCE", "melt")
source_ref_override = os.environ.get("SOURCE_REF", "")

with open(config_path, encoding="utf-8") as fh:
    presets = json.load(fh)

if kernel_source not in presets:
    allowed = ", ".join(sorted(presets))
    print(f'::error::Unknown kernel_source preset: {kernel_source}', file=sys.stderr)
    print(f"Allowed: {allowed}", file=sys.stderr)
    sys.exit(1)

preset = presets[kernel_source]
display = preset.get("display") or kernel_source
author = preset.get("author") or display
repo = preset.get("repo") or ""
default_ref = preset.get("default_ref") or ""
rom_label = preset.get("rom_label") or "HyperOS"
rom_family = preset.get("rom_family") or ""
rom_support = preset.get("rom_support") or ""
defconfig_mode = preset.get("defconfig_mode") or ""
defconfig = preset.get("defconfig") or ""
base_defconfig = preset.get("base_defconfig") or ""
fragments = preset.get("config_fragments") or []
config_fragments = " ".join(fragments)
recommended_toolchain = preset.get("recommended_toolchain") or ""
kernel_version = preset.get("kernel_version") or ""
# The SUSFS patch set must match the kernel version, so a preset that pins one
# wins over the caller-supplied default (the matrix always passes 5.10).
susfs_kernel_branch = (
    preset.get("susfs_kernel_branch")
    or os.environ.get("SUSFS_KERNEL_BRANCH", "")
    or "gki-android12-5.10"
)


def config_list(key):
    items = preset.get(key) or []
    for item in items:
        if not item or not all(c.isalnum() or c == "_" for c in item):
            print(f"::error::kernel_source {kernel_source} has invalid {key} entry: {item!r}", file=sys.stderr)
            sys.exit(1)
    return " ".join(items)


config_enable = config_list("config_enable")
config_disable = config_list("config_disable")
config_require = config_list("config_require")

rom_family_norm = (rom_family or "").lower()
if rom_family_norm == "los" or kernel_source in ("lineageos", "evolution-x", "evolution-x-6.6", "aosp-pablo", "pa-gr"):
    package_family = "LOS"
else:
    package_family = "MELT"

resolved_ref = source_ref_override or default_ref
if not resolved_ref:
    print(
        f"::error::kernel_source {kernel_source} has no default_ref and SOURCE_REF is empty",
        file=sys.stderr,
    )
    sys.exit(1)

if defconfig_mode == "single":
    if not defconfig:
        print(
            f"::error::kernel_source {kernel_source} uses single defconfig_mode but has no defconfig",
            file=sys.stderr,
        )
        sys.exit(1)
elif defconfig_mode == "gki_fragments":
    if not base_defconfig or not config_fragments:
        print(
            f"::error::kernel_source {kernel_source} uses gki_fragments but base_defconfig/config_fragments are incomplete",
            file=sys.stderr,
        )
        sys.exit(1)
else:
    print(
        f"::error::Unsupported defconfig_mode for {kernel_source}: {defconfig_mode}",
        file=sys.stderr,
    )
    sys.exit(1)

if not repo or "/" not in repo:
    print(f"::error::kernel_source {kernel_source} has invalid repo: {repo}", file=sys.stderr)
    sys.exit(1)

values = {
    "KERNEL_SOURCE": kernel_source,
    "KERNEL_SOURCE_DISPLAY": display,
    "KERNEL_SOURCE_AUTHOR": author,
    "SOURCE_REPO": repo,
    "SOURCE_REF": resolved_ref,
    "SUPPORTED_ROM_LABEL": rom_label,
    "ROM_FAMILY": rom_family,
    "ROM_SUPPORT": rom_support,
    "DEFCONFIG_MODE": defconfig_mode,
    "DEFCONFIG": defconfig,
    "BASE_DEFCONFIG": base_defconfig,
    "CONFIG_FRAGMENTS": config_fragments,
    "RECOMMENDED_TOOLCHAIN": recommended_toolchain,
    "PACKAGE_FAMILY": package_family,
    "KERNEL_VERSION": kernel_version,
    "SUSFS_KERNEL_BRANCH": susfs_kernel_branch,
    "CONFIG_ENABLE": config_enable,
    "CONFIG_DISABLE": config_disable,
    "CONFIG_REQUIRE": config_require,
}
os.makedirs("release", exist_ok=True)
with open("release/kernel-source.env", "w", encoding="utf-8") as fh:
    for k, v in values.items():
        fh.write(f"{k}={shlex.quote(v)}\n")

gh_env = os.environ.get("GITHUB_ENV")
if gh_env and os.path.exists(gh_env):
    with open(gh_env, "a", encoding="utf-8") as fh:
        for k, v in values.items():
            fh.write(f"{k}={v}\n")

gh_out = os.environ.get("GITHUB_OUTPUT")
if gh_out and os.path.exists(gh_out):
    with open(gh_out, "a", encoding="utf-8") as fh:
        for k in ("source_repo", "source_ref", "kernel_source", "kernel_source_display"):
            fh.write(f"{k}={values.get(k.upper(), '')}\n")

for key, value in values.items():
    print(f"{key}={shlex.quote(value)}")
PY
)"

echo "Resolved kernel source preset '${KERNEL_SOURCE}' (${KERNEL_SOURCE_AUTHOR})"
echo "  repo=${SOURCE_REPO}"
echo "  ref=${SOURCE_REF}"
echo "  rom_label=${SUPPORTED_ROM_LABEL}"
echo "  defconfig_mode=${DEFCONFIG_MODE}"
if [[ "${DEFCONFIG_MODE}" == "single" ]]; then
  echo "  defconfig=${DEFCONFIG}"
else
  echo "  base_defconfig=${BASE_DEFCONFIG}"
  echo "  fragments=${CONFIG_FRAGMENTS}"
fi
echo "  kernel_version=${KERNEL_VERSION:-unknown}"
echo "  susfs_kernel_branch=${SUSFS_KERNEL_BRANCH}"
for key in CONFIG_ENABLE CONFIG_DISABLE CONFIG_REQUIRE; do
  if [[ -n "${!key}" ]]; then
    echo "  ${key,,}=${!key}"
  fi
done
if [[ -n "${RECOMMENDED_TOOLCHAIN}" ]]; then
  echo "  recommended_toolchain=${RECOMMENDED_TOOLCHAIN}"
  if [[ -n "${TOOLCHAIN:-}" && "${TOOLCHAIN}" != "${RECOMMENDED_TOOLCHAIN}" ]]; then
    echo "::warning::kernel_source '${KERNEL_SOURCE}' recommends toolchain '${RECOMMENDED_TOOLCHAIN}' (selected: ${TOOLCHAIN}). Older Android clang may fail on armv9 flags."
  fi
fi
