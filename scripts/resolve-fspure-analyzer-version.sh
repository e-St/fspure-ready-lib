#!/usr/bin/env bash
# Print the FSharp.PureAnalyzer version to restore.
#
# Priority:
#   1. FspureAnalyzerVersion env if set and not "latest"
#   2. Latest version on GitHub Packages (org or user e-St)
#   3. Fallback: 0.3.2 (last known Phase-3 line on nuget.org / GH)
#
# Requires for (2): gh CLI + GH_TOKEN/GITHUB_TOKEN with packages:read
set -euo pipefail

OWNER="${FSPURE_GITHUB_OWNER:-e-St}"
PKG="FSharp.PureAnalyzer"
FALLBACK="${FSPURE_ANALYZER_FALLBACK_VERSION:-0.3.2}"

if [[ -n "${FspureAnalyzerVersion:-}" && "${FspureAnalyzerVersion}" != "latest" ]]; then
  echo "${FspureAnalyzerVersion}"
  exit 0
fi

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  echo "WARN: no GITHUB_TOKEN; cannot query GitHub Packages. Using fallback ${FALLBACK}." >&2
  echo "$FALLBACK"
  exit 0
fi

export GH_TOKEN="$TOKEN"

# GitHub Packages versions API (newest first). Try org, then user.
json=""
if json="$(gh api "/orgs/${OWNER}/packages/nuget/${PKG}/versions?per_page=20" 2>/dev/null)"; then
  :
elif json="$(gh api "/users/${OWNER}/packages/nuget/${PKG}/versions?per_page=20" 2>/dev/null)"; then
  :
else
  echo "WARN: could not list ${OWNER}/${PKG} on GitHub Packages. Using fallback ${FALLBACK}." >&2
  echo "$FALLBACK"
  exit 0
fi

# Prefer highest SemVer (handles 0.3.2 vs 0.1.0-preview).
ver="$(
  echo "$json" \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
names = [v.get("name") or v.get("metadata", {}).get("container", {}).get("tags", [None])[0] for v in data]
names = [n for n in names if n]
if not names:
    sys.exit(1)
# sort loosely by version parts
def key(s):
    parts = []
    for p in s.replace("-", ".").split("."):
        try:
            parts.append((0, int(p)))
        except ValueError:
            parts.append((1, p))
    return parts
print(sorted(names, key=key)[-1])
' 2>/dev/null || true
)"

if [[ -z "${ver:-}" ]]; then
  echo "WARN: empty version list from GitHub Packages. Using fallback ${FALLBACK}." >&2
  echo "$FALLBACK"
  exit 0
fi

echo "$ver"
