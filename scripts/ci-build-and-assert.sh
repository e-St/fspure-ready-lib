#!/usr/bin/env bash
# Build + pack Fspure.ReadyLib, assert embed, consumer diagnostics.
#
# Modes:
#   1) Inside fspure monorepo → delegates to scripts/fspure-ready-lib-gate.sh (local feed).
#   2) Standalone satellite → restore FSharp.PureAnalyzer from channel, pack ReadyLib, hard asserts.
#
# Standalone channels (FSPURE_ANALYZER_CHANNEL):
#   github-latest  — e-St GitHub Packages -ci.* builds (Phase 3 embed targets)
#   release        — nuget.org stable (only once that package ships build/ + tools/)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- Monorepo fast-path -------------------------------------------------------
MONOREPO="$(cd "$ROOT/../.." 2>/dev/null && pwd || true)"
if [[ -n "${MONOREPO:-}" \
   && -f "$MONOREPO/scripts/fspure-ready-lib-gate.sh" \
   && -f "$MONOREPO/FSharp.PureAnalyzer/FSharp.PureAnalyzer.fsproj" ]]; then
  echo "==> Monorepo detected — running scripts/fspure-ready-lib-gate.sh"
  exec bash "$MONOREPO/scripts/fspure-ready-lib-gate.sh"
fi

# --- Standalone satellite -----------------------------------------------------
CONFIGURATION="${CONFIGURATION:-Release}"
VERSION="${FspureReadyLibVersion:-0.1.0-preview.1}"
CHANNEL="${FSPURE_ANALYZER_CHANNEL:-github-latest}"
PKG_DIR="$ROOT/artifacts/packages"
mkdir -p "$PKG_DIR" "$ROOT/artifacts"

chmod +x scripts/*.sh 2>/dev/null || true

die() { echo "ERROR: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }
step() { echo ""; echo "==> $*"; }

step "Standalone mode (channel=${CHANNEL})"

if [[ "$CHANNEL" == "github-latest" ]]; then
  if [[ "${FSPURE_ANALYZER_PINNED:-0}" != "1" ]]; then
    if [[ -z "${FspureAnalyzerVersion:-}" \
       || "${FspureAnalyzerVersion}" == "latest" \
       || "${FspureAnalyzerVersion}" == "0.3.2" \
       || "${FspureAnalyzerVersion}" == "${FSPURE_ANALYZER_FALLBACK_VERSION:-0.3.2}" \
       || "${FspureAnalyzerVersion}" != *-ci.* ]]; then
      export FspureAnalyzerVersion=latest
    fi
  fi
  if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-${FSPURE_PACKAGES_READ_TOKEN:-}}}" ]]; then
    bash scripts/use-github-packages.sh
  elif [[ "${REQUIRE_GITHUB_PACKAGES:-0}" == "1" ]]; then
    die "GITHUB_TOKEN or FSPURE_PACKAGES_READ_TOKEN required for channel=github-latest"
  fi
fi

ANALYZER_VERSION="$(bash scripts/resolve-fspure-analyzer-version.sh)"
export FspureAnalyzerVersion="$ANALYZER_VERSION"
echo "Using FSharp.PureAnalyzer $ANALYZER_VERSION"

if [[ "$CHANNEL" == "github-latest" && "${REQUIRE_GITHUB_PACKAGES:-0}" == "1" ]]; then
  if [[ "$ANALYZER_VERSION" == "0.3.2" || "$ANALYZER_VERSION" != *-ci.* ]]; then
    die "channel=github-latest requires a -ci.* package (got $ANALYZER_VERSION). nuget.org 0.3.2 has no embed targets."
  fi
fi

step "Pack Fspure.ReadyLib $VERSION"
RESTORE_ARGS=()
if [[ "$CHANNEL" == "github-latest" ]]; then
  RESTORE_ARGS+=(
    "/p:RestoreAdditionalProjectSources=https://nuget.pkg.github.com/e-St/index.json"
  )
fi

dotnet pack src/Fspure.ReadyLib/Fspure.ReadyLib.fsproj \
  -c "$CONFIGURATION" \
  -o "$PKG_DIR" \
  --nologo \
  -v minimal \
  "/p:Version=$VERSION" \
  "/p:PackageVersion=$VERSION" \
  "/p:FspureAnalyzerVersion=$ANALYZER_VERSION" \
  "${RESTORE_ARGS[@]+"${RESTORE_ARGS[@]}"}"

GPF="${NUGET_PACKAGES:-$HOME/.nuget/packages}"
AN_PKG="$GPF/fsharp.pureanalyzer/$ANALYZER_VERSION"
step "Inspect analyzer package $AN_PKG"
[[ -d "$AN_PKG" ]] || {
  find "$GPF/fsharp.pureanalyzer" -maxdepth 2 -type d 2>/dev/null || true
  die "package folder missing after restore: $AN_PKG"
}
[[ -f "$AN_PKG/build/FSharp.PureAnalyzer.targets" ]] \
  || die "FSharp.PureAnalyzer $ANALYZER_VERSION has no build/ targets (not Phase 3). Use a -ci.* package from GitHub Packages."
# Collector tool path: current packages use tools/fspure-collector/;
# older Phase 3 CI packages used tools/purity-collector/ (pre-rename).
if [[ -f "$AN_PKG/tools/fspure-collector/fspure-collector.dll" \
   || -f "$AN_PKG/tools/fspure-collector/fspure-collector" ]]; then
  ok "Phase 3 package layout (tools/fspure-collector)"
elif [[ -f "$AN_PKG/tools/purity-collector/purity-collector.dll" \
   || -f "$AN_PKG/tools/purity-collector/purity-collector" ]]; then
  ok "Phase 3 package layout (legacy tools/purity-collector)"
else
  die "FSharp.PureAnalyzer $ANALYZER_VERSION missing tools/fspure-collector (or legacy tools/purity-collector)"
fi

DLL="$(find src/Fspure.ReadyLib/bin -name 'Fspure.ReadyLib.dll' 2>/dev/null | head -1 || true)"
[[ -n "$DLL" && -f "$DLL" ]] || die "Fspure.ReadyLib.dll not found after pack"

step "Assert embedded pure.json on $DLL"
dotnet run --project tests/AssertEmbed/AssertEmbed.fsproj -c "$CONFIGURATION" -- \
  "$DLL" \
  "Fspure.ReadyLib.Api.add" \
  "Fspure.ReadyLib.Api.mul" \
  "Fspure.ReadyLib.Api.manualEscapeHatch"
ok "DLL embed"

step "Restore + build consumer"
dotnet restore tests/Consumer/Consumer.fsproj \
  "/p:FspureReadyLibVersion=$VERSION"
dotnet build tests/Consumer/Consumer.fsproj \
  -c "$CONFIGURATION" \
  --nologo \
  "/p:FspureReadyLibVersion=$VERSION"
ok "consumer built"

step "Drop analyzer for fsharp-analyzers CLI"
ANALYZER_DROP="$ROOT/artifacts/analyzer-drop/dotnet/fs"
mkdir -p "$ANALYZER_DROP"
AN_DLL="$AN_PKG/analyzers/dotnet/fs/FSharp.PureAnalyzer.dll"
SCHEMA="$AN_PKG/analyzers/dotnet/fs/FSharp.PureSchema.dll"
[[ -f "$AN_DLL" ]] || die "analyzer DLL missing at $AN_DLL"
[[ -f "$SCHEMA" ]] || die "FSharp.PureSchema.dll missing next to analyzer"
cp -f "$AN_DLL" "$SCHEMA" "$ANALYZER_DROP/"

step "Run fsharp-analyzers on consumer"
dotnet tool restore
REPORT="$ROOT/artifacts/consumer.sarif"
STDOUT="$ROOT/artifacts/analyzer-stdout.txt"
set +e
dotnet tool run fsharp-analyzers -- \
  --project tests/Consumer/Consumer.fsproj \
  --analyzers-path "$ROOT/artifacts/analyzer-drop" \
  --configuration "$CONFIGURATION" \
  --report "$REPORT" \
  2>&1 | tee "$STDOUT"
ANALYZER_EXIT=$?
set -e

BODY="$(cat "$STDOUT" 2>/dev/null || true)"
if [[ -f "$REPORT" ]]; then
  BODY="${BODY}$(cat "$REPORT")"
fi

step "Hard asserts"
assert_contains() {
  local needle="$1"
  local label="$2"
  if ! grep -Fq "$needle" <<<"$BODY"; then
    tail -n 60 <<<"$BODY" >&2 || true
    die "$label — missing: $needle"
  fi
  ok "$label"
}
assert_absent() {
  local needle="$1"
  local label="$2"
  if grep -Fq "$needle" <<<"$BODY"; then
    die "$label — must not appear: $needle"
  fi
  ok "$label"
}

assert_contains "Function 'Consumer.useAdd' is transitively pure." \
  "useAdd PURE003 (library embed)"
assert_contains "Function 'Consumer.useImpure' is not transitively pure." \
  "useImpure PURE002"
assert_contains "Function 'Consumer.useFoundational' is transitively pure." \
  "useFoundational PURE003"
assert_contains "Function 'Consumer.useMap' is transitively pure." \
  "useMap PURE003"
assert_absent "Function 'Consumer.useAdd' is not transitively pure." \
  "useAdd must not be impure"
assert_absent "Function 'Consumer.useImpure' is transitively pure." \
  "useImpure must not be pure"
assert_contains "PURE002" "code PURE002 present"
assert_contains "PURE003" "code PURE003 present"

echo ""
echo "✅ ci-build-and-assert completed (exit=$ANALYZER_EXIT)"
echo "   channel:  $CHANNEL"
echo "   analyzer: $ANALYZER_VERSION"
echo "   packages: $PKG_DIR"
echo "   dll:      $DLL"
exit 0
