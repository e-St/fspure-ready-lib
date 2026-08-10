#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONO="$(cd "$ROOT/../../.." 2>/dev/null && pwd || true)"
if [[ -n "${MONO:-}" && -f "$MONO/src/Fspure.Tasks/Fspure.Tasks.fsproj" ]]; then
  exec dotnet run --project "$MONO/src/Fspure.Tasks/Fspure.Tasks.fsproj" -c "${CONFIGURATION:-Release}" -- assert-golden "$@"
fi
echo "ERROR: run from fspure monorepo (Fspure.Tasks)" >&2
exit 1
