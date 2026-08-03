#!/usr/bin/env bash
# Print the FSharp.PureAnalyzer version to restore.
#
# Channels (FSPURE_ANALYZER_CHANNEL):
#   release        — nuget.org stable pin / latest stable (customer)
#   github-latest  — most recently published version on e-St GitHub Packages
#                    (includes -ci.* prereleases from monorepo CI)
#
# Env:
#   FspureAnalyzerVersion=x.y.z | latest
#   FSPURE_ANALYZER_CHANNEL=release|github-latest
#   REQUIRE_GITHUB_PACKAGES=1
#   GITHUB_TOKEN or GH_TOKEN (packages:read). For cross-repo reads from
#   fspure-ready-lib, prefer secret FSPURE_PACKAGES_READ_TOKEN if GITHUB_TOKEN
#   cannot see packages published by e-St/fspure.
set -euo pipefail

OWNER="${FSPURE_GITHUB_OWNER:-e-St}"
PKG="FSharp.PureAnalyzer"
CHANNEL="${FSPURE_ANALYZER_CHANNEL:-release}"
FALLBACK="${FSPURE_ANALYZER_FALLBACK_VERSION:-0.3.2}"
REQUIRE="${REQUIRE_GITHUB_PACKAGES:-0}"

log() { echo "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

if [[ -n "${FspureAnalyzerVersion:-}" && "${FspureAnalyzerVersion}" != "latest" ]]; then
  log "Using explicit pin ${FspureAnalyzerVersion}"
  echo "${FspureAnalyzerVersion}"
  exit 0
fi

# ----- release channel (nuget.org) -----
if [[ "$CHANNEL" == "release" ]]; then
  if [[ "${FspureAnalyzerVersion:-}" == "latest" ]]; then
    ver="$(
      curl -fsSL "https://api.nuget.org/v3-flatcontainer/fsharp.pureanalyzer/index.json" \
        | python3 -c '
import json, sys
data = json.load(sys.stdin)
vers = [v for v in data.get("versions") or [] if "-" not in v]
if not vers:
    sys.exit(1)
print(sorted(vers, key=lambda s: tuple(int(x) for x in s.split(".")))[-1])
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

if [[ "$CHANNEL" != "github-latest" ]]; then
  die "Unknown FSPURE_ANALYZER_CHANNEL=${CHANNEL}"
fi

# ----- github-latest -----
# Prefer a dedicated packages-read token (can see monorepo-published packages).
TOKEN="${FSPURE_PACKAGES_READ_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
if [[ -z "$TOKEN" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    die "Token required for channel=github-latest (GITHUB_TOKEN or FSPURE_PACKAGES_READ_TOKEN)"
  fi
  log "WARN: no token; fallback ${FALLBACK}"
  echo "$FALLBACK"
  exit 0
fi

export GH_TOKEN="$TOKEN"
export GITHUB_TOKEN="$TOKEN"

# Prefer NuGet v3 query on the GitHub feed (same auth as restore). More reliable
# than the Packages REST API for cross-repo GITHUB_TOKEN limits.
query_url="https://nuget.pkg.github.com/${OWNER}/query?q=packageid:${PKG}&prerelease=true&semVerLevel=2.0.0"
log "Querying ${query_url}"
qjson="$(
  curl -fsSL \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "User-Agent: fspure-ready-lib-ci" \
    -H "Accept: application/vnd.nuget.v3.query+json, application/json" \
    "$query_url" 2>/dev/null || true
)"

ver=""
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
        return ((0, 0, 0, 0), (0, s))
    a, b, c, d, pre = m.groups()
    nums = tuple(int(x or 0) for x in (a, b, c, d))
    # For github-latest: higher numbers win; among same numbers, prerelease with
    # higher -ci.N wins over older prerelease; stable loses to a higher -ci of next patch.
    if pre:
        # extract trailing run number from ci.123 or ci.123.abc
        m2 = re.search(r"(\d+)$", pre.replace(".", " ").split()[-1] if False else pre)
        m2 = re.search(r"(\d+)(?:\D.*)?$", pre)
        n = int(m2.group(1)) if m2 else 0
        return (nums, (1, n, pre))  # prerelease marker 1
    return (nums, (2, 0, ""))  # stable after prereleases of same nums... wait we want newest BUILD

# Actually for "latest build" prefer max by: numeric version, then prefer ANY prerelease
# with higher ci number over stable of same base, then stable.
# Simpler: sort by (nums, ci_number, is_stable)
# 0.3.3-ci.5 > 0.3.2
# 0.3.2-ci.99 vs 0.3.2: for github-latest prefer higher ci over stable same base
def key(s: str):
    m = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-ci\.(\d+))?(?:[.+].*)?$", s, re.I)
    if m:
        a,b,c,ci = m.groups()
        nums = (int(a or 0), int(b or 0), int(c or 0))
        if ci is not None:
            return (nums, 1, int(ci))  # prerelease-ci
        return (nums, 0, 0)  # stable of that triple — below -ci of same triple? 
        # For same nums: we want -ci.N > previous -ci, but -ci.N vs stable:
        # prefer -ci as "newer build" when channel is github-latest: use (nums, 1, ci) > (nums, 0, 0)
    m = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-(.+))?$", s)
    a,b,c,pre = m.groups() if m else (0,0,0,s)
    nums = (int(a or 0), int(b or 0), int(c or 0))
    if pre:
        m2 = re.search(r"(\d+)", pre)
        return (nums, 1, int(m2.group(1)) if m2 else 0)
    return (nums, 0, 0)

print(sorted(set(names), key=key)[-1])
' 2>/dev/null || true
  )"
fi

# REST Packages API as second try (org then user); pick by updated_at then version
if [[ -z "${ver:-}" ]]; then
  log "NuGet query empty; trying Packages REST API..."
  for path in \
    "/orgs/${OWNER}/packages/nuget/${PKG}/versions?per_page=100" \
    "/users/${OWNER}/packages/nuget/${PKG}/versions?per_page=100"
  do
    json="$(gh api "$path" 2>/dev/null || true)"
    if [[ -z "$json" || "$json" == "[]" ]]; then
      continue
    fi
    ver="$(
      printf '%s' "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if not data:
    sys.exit(1)
# most recently updated first
data = sorted(data, key=lambda v: v.get("updated_at") or v.get("created_at") or "", reverse=True)
print(data[0]["name"])
' 2>/dev/null || true
    )"
    if [[ -n "${ver:-}" ]]; then
      log "Listed via REST ${path}"
      break
    fi
  done
fi

if [[ -z "${ver:-}" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    die "Could not list ${PKG} on GitHub Packages for ${OWNER}. Publish CI packages from e-St/fspure, and grant this repo packages:read (or set FSPURE_PACKAGES_READ_TOKEN)."
  fi
  log "WARN: fallback ${FALLBACK}"
  echo "$FALLBACK"
  exit 0
fi

log "Resolved ${PKG} ${ver} from GitHub Packages (${OWNER}) [channel=github-latest]"
echo "$ver"
