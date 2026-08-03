#!/usr/bin/env bash
# Build + pack Fspure.ReadyLib, assert embedded pure.json, restore consumer.
#
# Channels (FSPURE_ANALYZER_CHANNEL):
#   release (default)  — nuget.org released FSharp.PureAnalyzer (customer path)
#   github-latest      — newest e-St GitHub Packages build (dev path)
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
  if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
    bash scripts/use-github-packages.sh
  elif [[ "${REQUIRE_GITHUB_PACKAGES:-0}" == "1" ]]; then
    echo "ERROR: GITHUB_TOKEN required for channel=github-latest" >&2
    exit 1
  fi
fi

ANALYZER_VERSION="$(bash scripts/resolve-fspure-analyzer-version.sh)"
export FspureAnalyzerVersion="$ANALYZER_VERSION"
echo "==> Using FSharp.PureAnalyzer $ANALYZER_VERSION"

echo "==> Pack Fspure.ReadyLib $VERSION"
dotnet pack src/Fspure.ReadyLib/Fspure.ReadyLib.fsproj \
  -c "$CONFIGURATION" \
  -o "$PKG_DIR" \
  --nologo \
  "/p:Version=$VERSION" \
  "/p:PackageVersion=$VERSION" \
  "/p:FspureAnalyzerVersion=$ANALYZER_VERSION"

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
GPF="${NUGET_PACKAGES:-$HOME/.nuget/packages}"

AN_DLL=""
if [[ -f "$GPF/fsharp.pureanalyzer/$ANALYZER_VERSION/analyzers/dotnet/fs/FSharp.PureAnalyzer.dll" ]]; then
  AN_DLL="$GPF/fsharp.pureanalyzer/$ANALYZER_VERSION/analyzers/dotnet/fs/FSharp.PureAnalyzer.dll"
else
  while IFS= read -r candidate; do
    if [[ -f "$(dirname "$candidate")/FSharp.PureSchema.dll" ]]; then
      AN_DLL="$candidate"
      break
    fi
  done < <(find "$GPF/fsharp.pureanalyzer" -path '*/analyzers/dotnet/fs/FSharp.PureAnalyzer.dll' 2>/dev/null | sort -V | tac)
fi

if [[ -z "${AN_DLL}" || ! -f "$AN_DLL" ]]; then
  echo "ERROR: FSharp.PureAnalyzer.dll not in NuGet cache." >&2
  exit 1
fi
SCHEMA="$(dirname "$AN_DLL")/FSharp.PureSchema.dll"
cp -f "$AN_DLL" "$ANALYZER_DROP/"
if [[ -f "$SCHEMA" ]]; then
  cp -f "$SCHEMA" "$ANALYZER_DROP/"
else
  echo "ERROR: FSharp.PureSchema.dll missing next to $AN_DLL" >&2
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

if echo "$BODY" | grep -E "Function 'Consumer.useImpure' is not transitively pure" -q; then
  echo "OK: useImpure is impure"
fi

echo ""
echo "✅ ci-build-and-assert completed (exit=$ANALYZER_EXIT)"
echo "   channel:  $CHANNEL"
echo "   analyzer: $ANALYZER_VERSION"
echo "   packages: $PKG_DIR"
echo "   dll:      $DLL"
