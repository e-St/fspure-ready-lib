#!/usr/bin/env bash
# Unzip a Fspure.ReadyLib nupkg and assert the lib DLL embeds pure.json.
set -euo pipefail

NUPKG="${1:-}"
if [[ -z "$NUPKG" || ! -f "$NUPKG" ]]; then
  echo "usage: $0 <Fspure.ReadyLib.*.nupkg>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unzip -q "$NUPKG" -d "$TMP"
DLL="$(find "$TMP" -name 'Fspure.ReadyLib.dll' | head -1 || true)"
if [[ -z "$DLL" ]]; then
  echo "ERROR: Fspure.ReadyLib.dll missing from nupkg" >&2
  find "$TMP" -type f | head -50 >&2
  exit 1
fi

dotnet run --project "$ROOT/tests/AssertEmbed/AssertEmbed.fsproj" -c Release -- \
  "$DLL" \
  "Fspure.ReadyLib.Api.add" \
  "Fspure.ReadyLib.Api.manualEscapeHatch"

echo "✅ nupkg embed OK: $NUPKG"
