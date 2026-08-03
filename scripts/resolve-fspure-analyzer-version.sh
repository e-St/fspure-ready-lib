#!/usr/bin/env bash
# Print the FSharp.PureAnalyzer version to restore.
#
# Modes (FSPURE_ANALYZER_CHANNEL):
#   release (default) — released versions only (nuget.org / pin)
#   github-latest     — newest version on e-St GitHub Packages (prereleases OK)
#
# Env:
#   FspureAnalyzerVersion=x.y.z | latest
#   FSPURE_ANALYZER_CHANNEL=release|github-latest
#   REQUIRE_GITHUB_PACKAGES=1  — fail if github-latest cannot be resolved
#   GITHUB_TOKEN / GH_TOKEN    — required for github-latest
set -euo pipefail

OWNER="${FSPURE_GITHUB_OWNER:-e-St}"
PKG="FSharp.PureAnalyzer"
CHANNEL="${FSPURE_ANALYZER_CHANNEL:-release}"
FALLBACK="${FSPURE_ANALYZER_FALLBACK_VERSION:-0.3.2}"
REQUIRE="${REQUIRE_GITHUB_PACKAGES:-0}"

log() { echo "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Explicit pin always wins (except the sentinel "latest").
if [[ -n "${FspureAnalyzerVersion:-}" && "${FspureAnalyzerVersion}" != "latest" ]]; then
  echo "${FspureAnalyzerVersion}"
  exit 0
fi

# --- release channel: prefer nuget.org latest stable, else fallback pin ---
if [[ "$CHANNEL" == "release" ]]; then
  if [[ "${FspureAnalyzerVersion:-}" == "latest" ]]; then
    # nuget.org service index query for latest stable
    ver="$(
      curl -fsSL "https://api.nuget.org/v3-flatcontainer/fsharp.pureanalyzer/index.json" 2>/dev/null \
        | python3 -c '
import json, sys, re
data = json.load(sys.stdin)
vers = [v for v in data.get("versions") or [] if "-" not in v]
if not vers:
    sys.exit(1)
def key(s):
    return tuple(int(x) for x in s.split("."))
print(sorted(vers, key=key)[-1])
' 2>/dev/null || true
    )"
    if [[ -n "${ver:-}" ]]; then
      log "Resolved ${PKG} ${ver} from nuget.org (stable)"
      echo "$ver"
      exit 0
    fi
  fi
  log "Using released pin ${FALLBACK} (channel=release)"
  echo "$FALLBACK"
  exit 0
fi

# --- github-latest channel ---
if [[ "$CHANNEL" != "github-latest" ]]; then
  die "Unknown FSPURE_ANALYZER_CHANNEL=${CHANNEL} (use release or github-latest)"
fi

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    die "GITHUB_TOKEN required for channel=github-latest"
  fi
  log "WARN: no token; falling back to ${FALLBACK}"
  echo "$FALLBACK"
  exit 0
fi

export GH_TOKEN="$TOKEN"
export GITHUB_TOKEN="$TOKEN"

json=""
if json="$(gh api "/orgs/${OWNER}/packages/nuget/${PKG}/versions?per_page=100" 2>/dev/null)"; then
  log "Listed ${PKG} via org packages API"
elif json="$(gh api "/users/${OWNER}/packages/nuget/${PKG}/versions?per_page=100" 2>/dev/null)"; then
  log "Listed ${PKG} via user packages API"
else
  json=""
fi

pick_newest() {
  python3 -c '
import json, sys, re
data = json.load(sys.stdin)
if not isinstance(data, list) or not data:
    sys.exit(1)
names = [str(v["name"]) for v in data if v.get("name")]
if not names:
    sys.exit(1)

def semver_key(s: str):
    m = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?(?:-(.+))?$", s)
    if not m:
        return (0, 0, 0, 0, (1, s))
    a, b, c, d, pre = m.groups()
    nums = tuple(int(x or 0) for x in (a, b, c, d))
    # Stable (no prerelease) sorts after prerelease for same numbers
    pre_key = (1, pre) if pre else (0, "")
    return (*nums, pre_key)

print(sorted(names, key=semver_key)[-1])
'
}

ver=""
if [[ -n "$json" ]]; then
  ver="$(printf '%s' "$json" | pick_newest || true)"
fi

if [[ -z "${ver:-}" ]]; then
  query_url="https://nuget.pkg.github.com/${OWNER}/query?q=packageid:${PKG}&prerelease=true&semVerLevel=2.0.0"
  qjson="$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/json" "$query_url" 2>/dev/null || true)"
  if [[ -n "$qjson" ]]; then
    ver="$(
      printf '%s' "$qjson" | python3 -c '
import json, sys, re
data = json.load(sys.stdin)
names = []
for d in data.get("data") or []:
    if d.get("id", "").lower() != "fsharp.pureanalyzer":
        continue
    if d.get("version"):
        names.append(d["version"])
    for v in d.get("versions") or []:
        if v.get("version"):
            names.append(v["version"])
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
    die "Could not resolve ${PKG} from GitHub Packages owner=${OWNER}"
  fi
  log "WARN: empty GH list; fallback ${FALLBACK}"
  echo "$FALLBACK"
  exit 0
fi

log "Resolved ${PKG} ${ver} from GitHub Packages (${OWNER})"
echo "$ver"
