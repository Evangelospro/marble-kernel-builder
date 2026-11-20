#!/usr/bin/env bash
# Find the official, production-signed manager app build that matches the
# kernel exactly. Prints shell assignments (for eval):
#   manager_apk_repo= manager_apk_artifact_id= manager_apk_run_id= manager_apk_commit=
# Empty values mean "no exact official build": the zip then bundles no app and
# no ksud (better than a mismatched one).
#
# Inputs (env): MANAGER, MANAGER_REPO (effective repo, may be a SUSFS fork),
# MANAGER_REF (branch/tag/sha), MANAGER_COMMIT (resolved head of the ref).
set -euo pipefail

MANAGER="${MANAGER:-none}"
MANAGER_REPO="${MANAGER_REPO:-}"
MANAGER_REF="${MANAGER_REF:-}"
MANAGER_COMMIT="${MANAGER_COMMIT:-}"

emit() {
  printf 'manager_apk_repo=%q\nmanager_apk_artifact_id=%q\nmanager_apk_run_id=%q\nmanager_apk_commit=%q\n' \
    "${1:-}" "${2:-}" "${3:-}" "${4:-}"
}

build_repo="$(jq -r --arg m "${MANAGER}" '.[$m].apk_build.repo // empty' config/managers.json)"
workflow="$(jq -r --arg m "${MANAGER}" '.[$m].apk_build.workflow // empty' config/managers.json)"
artifact="$(jq -r --arg m "${MANAGER}" '.[$m].apk_build.artifact // empty' config/managers.json)"
main_repo="$(jq -r --arg m "${MANAGER}" '.[$m].repo // empty' config/managers.json)"

if [[ -z "${build_repo}" || -z "${workflow}" || -z "${artifact}" ]]; then
  echo "::warning::No official per-commit app build is known for ${MANAGER}; the zip will not bundle the app or ksud (install the matching app yourself)" >&2
  emit; exit 0
fi
# Official builds only exist for the official repo, not for SUSFS forks.
if [[ "${MANAGER_REPO,,}" != "${main_repo,,}" && "${MANAGER_REPO,,}" != "${build_repo,,}" ]]; then
  echo "::warning::${MANAGER_REPO} is a fork without official-signed app builds; the zip will not bundle the app or ksud (install the matching app yourself)" >&2
  emit; exit 0
fi

api_get() {
  if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
    gh api "$1"
  else
    curl -fsSL -H 'Accept: application/vnd.github+json' \
      ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} "https://api.github.com/$1"
  fi
}

# Successful push builds (production key) for this exact commit, or for the
# branch (newest first) when the ref is a branch.
if [[ "${MANAGER_REF}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  query="head_sha=${MANAGER_REF}"
else
  query="branch=${MANAGER_REF}"
fi
if ! runs="$(api_get "repos/${build_repo}/actions/workflows/${workflow}/runs?${query}&event=push&status=success&per_page=50")"; then
  echo "::warning::Could not list ${build_repo} ${workflow} runs; the zip will not bundle the app or ksud" >&2
  emit; exit 0
fi

while IFS=$'\t' read -r run_id head_sha; do
  [[ -n "${run_id}" ]] || continue
  if ! arts="$(api_get "repos/${build_repo}/actions/runs/${run_id}/artifacts?per_page=100")"; then
    continue
  fi
  art_id="$(printf '%s' "${arts}" | jq -r --arg n "${artifact}" \
    '[.artifacts[] | select(.name == $n and (.expired | not))][0].id // empty')"
  if [[ -n "${art_id}" ]]; then
    echo "Official ${MANAGER} app build: ${build_repo} run ${run_id}, commit ${head_sha}, artifact ${artifact} (${art_id})" >&2
    emit "${build_repo}" "${art_id}" "${run_id}" "${head_sha}"
    exit 0
  fi
done < <(printf '%s' "${runs}" | jq -r '.workflow_runs | sort_by(.created_at) | reverse | .[] | "\(.id)\t\(.head_sha)"')

echo "::warning::No unexpired official ${artifact} build found for ${build_repo}@${MANAGER_REF} (head ${MANAGER_COMMIT:0:12}); the zip will not bundle the app or ksud" >&2
emit
