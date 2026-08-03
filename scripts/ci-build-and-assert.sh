#!/usr/bin/env bash
# Build + pack Fspure.ReadyLib, assert embedded pure.json, restore consumer.
#
# Channels (FSPURE_ANALYZER_CHANNEL):
#   release (default)  — nuget.org released FSharp.PureAnalyzer (customer / main)
#   github-latest      — newest e-St GitHub Packages -ci.* build (dev)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
VERSION="${FspureReadyLibVersion:-0.1.0-preview.1}"
CHANNEL="${FSPURE_ANALYZER_CHANNEL:-release}"
PKG_DIR="$ROOT/artifacts/packages"
mkdir -p "$PKG_DIR" "$ROOT/artifacts"

chmod +x scripts/*.sh 2>/dev/null || true

echo "==> Analyzer channel: ${CHANNEL}"

if [[ "$CHANNEL" == "github-latest" ]]; then
  # Never keep a customer release pin in the environment for the dev channel
  # unless the resolve step explicitly pinned a concrete -ci.* version.
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
    echo "ERROR: GITHUB_TOKEN or FSPURE_PACKAGES_READ_TOKEN required for channel=github-latest" >&2
    exit 1
  fi
fi

ANALYZER_VERSION="$(bash scripts/resolve-fspure-analyzer-version.sh)"
export FspureAnalyzerVersion="$ANALYZER_VERSION"
echo "==> Using FSharp.PureAnalyzer $ANALYZER_VERSION"

if [[ "$CHANNEL" == "github-latest" && "${REQUIRE_GITHUB_PACKAGES:-0}" == "1" ]]; then
  if [[ "$ANALYZER_VERSION" == "0.3.2" || "$ANALYZER_VERSION" != *-ci.* ]]; then
    echo "ERROR: channel=github-latest requires a -ci.* package (got $ANALYZER_VERSION)." >&2
    echo "nuget.org and mirrored 0.3.2 have no build/ embed targets." >&2
    exit 1
  fi
fi

echo "==> Pack Fspure.ReadyLib $VERSION"
# On github-latest, prefer restoring the analyzer from the github-e-st source first.
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

# Prove the restored analyzer package contains Phase 3 embed tooling.
GPF="${NUGET_PACKAGES:-$HOME/.nuget/packages}"
AN_PKG="$GPF/fsharp.pureanalyzer/$ANALYZER_VERSION"
echo "==> Inspect analyzer package $AN_PKG"
if [[ ! -d "$AN_PKG" ]]; then
  echo "ERROR: package folder missing after restore: $AN_PKG" >&2
  find "$GPF/fsharp.pureanalyzer" -maxdepth 2 -type d 2>/dev/null || true
  exit 1
fi
ls -la "$AN_PKG/build" 2>/dev/null || echo "WARN: no build/ folder"
ls -la "$AN_PKG/tools/purity-collector" 2>/dev/null | head -20 || echo "WARN: no tools/purity-collector"
if [[ ! -f "$AN_PKG/build/FSharp.PureAnalyzer.targets" ]]; then
  echo "ERROR: FSharp.PureAnalyzer $ANALYZER_VERSION has no build/FSharp.PureAnalyzer.targets (not a Phase 3 package)." >&2
  echo "       nuget.org 0.3.2 is analyzer-only; use a 0.3.2-ci.* build from GitHub Packages." >&2
  exit 1
fi
if [[ ! -f "$AN_PKG/tools/purity-collector/purity-collector.dll" \
   && ! -f "$AN_PKG/tools/purity-collector/purity-collector" ]]; then
  echo "ERROR: FSharp.PureAnalyzer $ANALYZER_VERSION missing purity-collector under tools/." >&2
  exit 1
fi

DLL="$(find src/Fspure.ReadyLib/bin -name 'Fspure.ReadyLib.dll' 2>/dev/null | head -1 || true)"
if [[ -z "$DLL" || ! -f "$DLL" ]]; then
  echo "ERROR: Fspure.ReadyLib.dll not found after pack/build" >&2
  exit 1
fi

echo "==> Assert embedded pure.json on $DLL"
dotnet run --project tests/AssertEmbed/AssertEmbed.fsproj -c "$CONFIGURATION" -- \
  "$DLL" \
  "Fspure.ReadyLib.Api.add" \
  "Fspure.ReadyLib.Api.mul" \
  "Fspure.ReadyLib.Api.manualEscapeHatch"

echo "==> Restore consumer against local feed"
dotnet restore tests/Consumer/Consumer.fsproj \
  "/p:FspureReadyLibVersion=$VERSION"

dotnet build tests/Consumer/Consumer.fsproj \
  -c "$CONFIGURATION" \
  --nologo \
  "/p:FspureReadyLibVersion=$VERSION"

echo "==> Drop FSharp.PureAnalyzer for fsharp-analyzers CLI"
ANALYZER_DROP="$ROOT/artifacts/analyzer-drop/dotnet/fs"
mkdir -p "$ANALYZER_DROP"
AN_DLL="$AN_PKG/analyzers/dotnet/fs/FSharp.PureAnalyzer.dll"
SCHEMA="$AN_PKG/analyzers/dotnet/fs/FSharp.PureSchema.dll"
if [[ ! -f "$AN_DLL" ]]; then
  echo "ERROR: analyzer DLL missing at $AN_DLL" >&2
  exit 1
fi
cp -f "$AN_DLL" "$ANALYZER_DROP/"
if [[ -f "$SCHEMA" ]]; then
  cp -f "$SCHEMA" "$ANALYZER_DROP/"
else
  echo "ERROR: FSharp.PureSchema.dll missing next to analyzer" >&2
  exit 1
fi
echo "    analyzer → $AN_DLL"

echo "==> Run fsharp-analyzers on consumer"
dotnet tool restore
REPORT="$ROOT/artifacts/consumer.sarif"
set +e
dotnet tool run fsharp-analyzers -- \
  --project tests/Consumer/Consumer.fsproj \
  --analyzers-path "$ROOT/artifacts/analyzer-drop" \
  --configuration "$CONFIGURATION" \
  --report "$REPORT" \
  2>&1 | tee "$ROOT/artifacts/analyzer-stdout.txt"
ANALYZER_EXIT=$?
set -e

BODY="$(cat "$ROOT/artifacts/analyzer-stdout.txt" 2>/dev/null || true)"
if [[ -f "$REPORT" ]]; then
  BODY="${BODY}$(cat "$REPORT")"
fi

echo "$BODY" | grep -q 'useAdd' || { echo "ERROR: no diagnostic mentioning useAdd"; exit 1; }
echo "$BODY" | grep -q 'useImpure' || { echo "ERROR: no diagnostic mentioning useImpure"; exit 1; }
echo "$BODY" | grep -q 'PURE002' || { echo "ERROR: expected PURE002"; exit 1; }
echo "$BODY" | grep -q 'PURE003' || { echo "ERROR: expected PURE003"; exit 1; }

if echo "$BODY" | grep -E "Function 'Consumer.useAdd' is transitively pure" -q; then
  echo "OK: useAdd is pure (library embed consumed)"
else
  echo "WARN: useAdd was not clearly PURE003"
fi

echo ""
echo "✅ ci-build-and-assert completed (exit=$ANALYZER_EXIT)"
echo "   channel:  $CHANNEL"
echo "   analyzer: $ANALYZER_VERSION"
echo "   packages: $PKG_DIR"
echo "   dll:      $DLL"
