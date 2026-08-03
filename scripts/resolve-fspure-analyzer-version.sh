#!/usr/bin/env bash
# Print the FSharp.PureAnalyzer version to restore from e-St GitHub Packages.
#
# Priority:
#   1. FspureAnalyzerVersion if set and not "latest"
#   2. Newest version listed on GitHub Packages (includes prereleases / CI builds)
#   3. If REQUIRE_GITHUB_PACKAGES=1 (CI default): fail hard
#      else: fall back to FSPURE_ANALYZER_FALLBACK_VERSION (0.3.2)
#
# Requires for (2): GH_TOKEN or GITHUB_TOKEN with packages:read
set -euo pipefail

OWNER="${FSPURE_GITHUB_OWNER:-e-St}"
PKG="FSharp.PureAnalyzer"
FALLBACK="${FSPURE_ANALYZER_FALLBACK_VERSION:-0.3.2}"
REQUIRE="${REQUIRE_GITHUB_PACKAGES:-0}"

log() { echo "$*" >&2; }

die() {
  log "ERROR: $*"
  exit 1
}

if [[ -n "${FspureAnalyzerVersion:-}" && "${FspureAnalyzerVersion}" != "latest" ]]; then
  echo "${FspureAnalyzerVersion}"
  exit 0
fi

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    die "GITHUB_TOKEN required to resolve latest FSharp.PureAnalyzer from GitHub Packages."
  fi
  log "WARN: no GITHUB_TOKEN; using fallback ${FALLBACK}."
  echo "$FALLBACK"
  exit 0
fi

export GH_TOKEN="$TOKEN"
export GITHUB_TOKEN="$TOKEN"

# --- 1) GitHub Packages REST API (org then user) ---
fetch_versions_json() {
  local path="$1"
  gh api "$path" 2>/dev/null || return 1
}

json=""
if json="$(fetch_versions_json "/orgs/${OWNER}/packages/nuget/${PKG}/versions?per_page=100")"; then
  log "OK: listed ${PKG} via /orgs/${OWNER}/packages/nuget/..."
elif json="$(fetch_versions_json "/users/${OWNER}/packages/nuget/${PKG}/versions?per_page=100")"; then
  log "OK: listed ${PKG} via /users/${OWNER}/packages/nuget/..."
else
  json=""
fi

pick_newest() {
  python3 -c '
import json, sys, re

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception as e:
    sys.stderr.write(f"parse error: {e}\n")
    sys.exit(1)

if not isinstance(data, list) or not data:
    sys.exit(1)

names = []
for v in data:
    n = v.get("name")
    if n:
        names.append(str(n))

if not names:
    sys.exit(1)

def semver_key(s: str):
    # Split main + prerelease; numeric where possible
    m = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?(?:-(.+))?$", s)
    if not m:
        return (0, 0, 0, 0, s)
    a, b, c, d, pre = m.groups()
    nums = tuple(int(x or 0) for x in (a, b, c, d))
    # No prerelease sorts after prerelease of same numbers (stable > preview)
    pre_key = (1, pre) if pre else (0, "")
    return (*nums, pre_key)

print(sorted(names, key=semver_key)[-1])
'
}

ver=""
if [[ -n "$json" ]]; then
  ver="$(printf '%s' "$json" | pick_newest || true)"
fi

# --- 2) Fallback: NuGet v3 query on GitHub Packages feed ---
if [[ -z "${ver:-}" ]]; then
  log "REST package versions empty; trying NuGet v3 query on github-e-st..."
  # Service index → SearchQueryService
  query_url="https://nuget.pkg.github.com/${OWNER}/query?q=packageid:${PKG}&prerelease=true&semVerLevel=2.0.0"
  qjson="$(
    curl -fsSL \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: application/json" \
      "$query_url" 2>/dev/null || true
  )"
  if [[ -n "$qjson" ]]; then
    ver="$(
      printf '%s' "$qjson" | python3 -c '
import json, sys, re
data = json.load(sys.stdin)
names = []
for d in data.get("data") or []:
    if d.get("id", "").lower() == "fsharp.pureanalyzer":
        for v in d.get("versions") or []:
            n = v.get("version")
            if n:
                names.append(n)
        # some feeds only put latest in top-level version
        if d.get("version"):
            names.append(d["version"])
if not names:
    sys.exit(1)

def semver_key(s: str):
    m = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?(?:-(.+))?$", s)
    if not m:
        return (0, 0, 0, 0, (1, s))
    a, b, c, d, pre = m.groups()
    nums = tuple(int(x or 0) for x in (a, b, c, d))
    pre_key = (1, pre) if pre else (0, "")
    return (*nums, pre_key)

print(sorted(set(names), key=semver_key)[-1])
' 2>/dev/null || true
    )"
  fi
fi

if [[ -z "${ver:-}" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    die "Could not resolve latest ${PKG} from GitHub Packages owner=${OWNER}. Is the package published under e-St? Does GITHUB_TOKEN have packages:read?"
  fi
  log "WARN: empty version list; using fallback ${FALLBACK}."
  echo "$FALLBACK"
  exit 0
fi

log "Resolved ${PKG} ${ver} from GitHub Packages (${OWNER})"
echo "$ver"
