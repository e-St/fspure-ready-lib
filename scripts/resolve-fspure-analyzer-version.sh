#!/usr/bin/env bash
# Print the FSharp.PureAnalyzer version to restore.
#
# Channels (FSPURE_ANALYZER_CHANNEL):
#   release        — nuget.org stable (customer / main)
#   github-latest  — newest -ci.* build on e-St GitHub Packages (dev)
#
# On github-latest:
#   - A bare pin of the release fallback (0.3.2) is IGNORED unless
#     FSPURE_ANALYZER_PINNED=1 (stale GITHUB_ENV must not block CI packages).
#   - With REQUIRE_GITHUB_PACKAGES=1, resolution MUST land on a -ci.* version
#     (nuget.org 0.3.2 and the mirrored GH 0.3.2 lack Phase 3 embed tooling).
set -euo pipefail

OWNER="${FSPURE_GITHUB_OWNER:-e-St}"
PKG="FSharp.PureAnalyzer"
CHANNEL="${FSPURE_ANALYZER_CHANNEL:-release}"
FALLBACK="${FSPURE_ANALYZER_FALLBACK_VERSION:-0.3.2}"
REQUIRE="${REQUIRE_GITHUB_PACKAGES:-0}"
PINNED="${FSPURE_ANALYZER_PINNED:-0}"

log() { echo "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

is_ci_prerelease() {
  [[ "$1" =~ -ci\.[0-9]+ ]]
}

# ----- honor explicit pin -----
if [[ -n "${FspureAnalyzerVersion:-}" && "${FspureAnalyzerVersion}" != "latest" ]]; then
  if [[ "$CHANNEL" == "github-latest" && "$PINNED" != "1" ]]; then
    if [[ "${FspureAnalyzerVersion}" == "$FALLBACK" \
       || "${FspureAnalyzerVersion}" == "0.3.2" ]] \
       || ! is_ci_prerelease "${FspureAnalyzerVersion}"; then
      log "Ignoring non-CI pin ${FspureAnalyzerVersion} on channel=github-latest (set FSPURE_ANALYZER_PINNED=1 to force)."
      export FspureAnalyzerVersion=latest
    else
      log "Using pin ${FspureAnalyzerVersion} (channel=github-latest)"
      echo "${FspureAnalyzerVersion}"
      exit 0
    fi
  else
    log "Using explicit pin ${FspureAnalyzerVersion}"
    echo "${FspureAnalyzerVersion}"
    exit 0
  fi
fi

# ----- release channel -----
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

# ----- github-latest: query e-St GitHub Packages -----
TOKEN="${FSPURE_PACKAGES_READ_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
if [[ -z "$TOKEN" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    die "Token required for github-latest (FSPURE_PACKAGES_READ_TOKEN or GITHUB_TOKEN with packages:read)"
  fi
  log "WARN: no token; fallback ${FALLBACK}"
  echo "$FALLBACK"
  exit 0
fi

export GH_TOKEN="$TOKEN"
export GITHUB_TOKEN="$TOKEN"

query_url="https://nuget.pkg.github.com/${OWNER}/query?q=packageid:${PKG}&prerelease=true&semVerLevel=2.0.0"
log "Querying GitHub Packages: ${query_url}"
http_code="$(
  curl -sS -o /tmp/fspure-nuget-query.json -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "User-Agent: fspure-ready-lib-ci" \
    -H "Accept: application/json" \
    "$query_url" 2>/dev/null || echo "000"
)"
log "NuGet query HTTP ${http_code}"

ver=""
if [[ "$http_code" == "200" && -s /tmp/fspure-nuget-query.json ]]; then
  if python3 - <<'PY' >/tmp/fspure-resolve-ver.txt 2>/tmp/fspure-resolve-versions.txt
import json, re, sys
with open("/tmp/fspure-nuget-query.json") as f:
    data = json.load(f)
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

def key(s: str):
    # Prefer higher major.minor.patch; among same triple prefer -ci.N over stable.
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-ci\.(\d+))?", s, re.I)
    if m:
        a, b, c, ci = m.groups()
        nums = (int(a), int(b), int(c))
        if ci is not None:
            return (nums, 1, int(ci), s)
        return (nums, 0, 0, s)
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$", s)
    if not m:
        return ((0, 0, 0), 0, 0, s)
    a, b, c, pre = m.groups()
    nums = (int(a), int(b), int(c))
    if pre:
        m2 = re.search(r"(\d+)", pre)
        return (nums, 1, int(m2.group(1)) if m2 else 0, s)
    return (nums, 0, 0, s)

uniq = sorted(set(names), key=key)
ci = [v for v in uniq if re.search(r"-ci\.\d+", v, re.I)]
print("FOUND:" + ",".join(uniq[-12:]), file=sys.stderr)
print("CI:" + (",".join(ci[-8:]) if ci else "(none)"), file=sys.stderr)
# For github-latest always prefer a -ci prerelease when any exist.
if ci:
    print(sorted(ci, key=key)[-1])
else:
    print(uniq[-1])
PY
  then
    ver="$(tr -d '[:space:]' </tmp/fspure-resolve-ver.txt)"
  fi
  if [[ -f /tmp/fspure-resolve-versions.txt ]]; then
    while IFS= read -r line; do log "$line"; done < /tmp/fspure-resolve-versions.txt
  fi
fi

# Packages REST API fallback (by updated_at) — often 403 for GITHUB_TOKEN across repos
if [[ -z "${ver:-}" ]] && command -v gh >/dev/null 2>&1; then
  log "Trying Packages REST API (org/user)..."
  for path in \
    "/orgs/${OWNER}/packages/nuget/${PKG}/versions?per_page=100" \
    "/users/${OWNER}/packages/nuget/${PKG}/versions?per_page=100"
  do
    json="$(gh api "$path" 2>/dev/null || true)"
    log "REST ${path} -> $( [[ -n "$json" && "$json" != "[]" ]] && echo ok || echo empty )"
    if [[ -z "$json" || "$json" == "[]" ]]; then
      continue
    fi
    ver="$(
      printf '%s' "$json" | python3 -c '
import json, sys, re
data = json.load(sys.stdin)
if not data:
    sys.exit(1)
ci = [v for v in data if re.search(r"-ci\.\d+", v.get("name") or "", re.I)]
pool = ci if ci else data
pool = sorted(pool, key=lambda v: v.get("updated_at") or v.get("created_at") or "", reverse=True)
print("FOUND:" + ",".join(v.get("name","") for v in pool[:10]), file=sys.stderr)
print(pool[0]["name"])
' 2>/tmp/fspure-resolve-versions.txt || true
    )"
    if [[ -n "${ver:-}" ]]; then
      log "$(cat /tmp/fspure-resolve-versions.txt 2>/dev/null || true)"
      break
    fi
  done
fi

if [[ -z "${ver:-}" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    die "No ${PKG} versions on GitHub Packages for ${OWNER}. Publish from e-St/fspure (workflow: Publish analyzer to GitHub Packages), and grant this workflow packages:read (package Actions access or FSPURE_PACKAGES_READ_TOKEN)."
  fi
  log "WARN: fallback ${FALLBACK}"
  echo "$FALLBACK"
  exit 0
fi

# Hard requirement: dev channel needs a Phase 3 CI prerelease, not the old 0.3.2 mirror.
if [[ "$REQUIRE" == "1" && "$PINNED" != "1" ]]; then
  if ! is_ci_prerelease "$ver"; then
    die "Resolved ${ver} but no -ci.* prerelease is visible on GitHub Packages yet.
  - Wait for monorepo workflow 'Publish analyzer to GitHub Packages (CI)' to finish
  - Or grant package Actions access / set FSPURE_PACKAGES_READ_TOKEN
  - Newest query result was: ${ver}
  nuget.org and mirrored ${FALLBACK} lack build/ embed targets (no pure.json)."
  fi
fi

if [[ "$ver" == "0.3.2" || "$ver" == "$FALLBACK" ]]; then
  log "WARN: newest GitHub Packages version is ${ver} (no -ci.* build found yet)."
fi

log "Resolved ${PKG} ${ver} [channel=github-latest owner=${OWNER}]"
echo "$ver"
