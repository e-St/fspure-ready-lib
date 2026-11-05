#!/usr/bin/env bash
# Assert a Fspure.ReadyLib nupkg contains a DLL with embedded pure.json.
#
# Monorepo: delegates to Fspure.Tasks (same checks).
# Satellite: unzip the nupkg and run tests/AssertEmbed (no monorepo required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NUPKG="${1:-}"
if [[ -z "$NUPKG" || ! -f "$NUPKG" ]]; then
  echo "usage: assert-nupkg-embed.sh <Fspure.ReadyLib.*.nupkg>" >&2
  exit 2
fi
NUPKG="$(cd "$(dirname "$NUPKG")" && pwd)/$(basename "$NUPKG")"

MONO="$(cd "$ROOT/../../.." 2>/dev/null && pwd || true)"
if [[ -n "${MONO:-}" && -f "$MONO/src/Fspure.Tasks/Fspure.Tasks.fsproj" ]]; then
  exec dotnet run --project "$MONO/src/Fspure.Tasks/Fspure.Tasks.fsproj" -c "${CONFIGURATION:-Release}" -- assert-nupkg "$NUPKG"
fi

CONFIGURATION="${CONFIGURATION:-Release}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$NUPKG" "$TMP" <<'PY'
import sys, zipfile
nupkg, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(nupkg) as zf:
    zf.extractall(dest)
PY

DLL="$(find "$TMP" -name 'Fspure.ReadyLib.dll' -type f | head -1 || true)"
if [[ -z "$DLL" ]]; then
  echo "ERROR: Fspure.ReadyLib.dll missing from nupkg: $NUPKG" >&2
  exit 1
fi

dotnet run --project "$ROOT/tests/AssertEmbed/AssertEmbed.fsproj" -c "$CONFIGURATION" -- \
  "$DLL" \
  "Fspure.ReadyLib.Api.add" \
  "Fspure.ReadyLib.Api.manualEscapeHatch"
echo "OK: nupkg embed $NUPKG"
