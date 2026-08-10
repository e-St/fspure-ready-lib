#!/usr/bin/env bash
# Sample entrypoint.
#
# In the fspure monorepo this delegates to the single Phase 4 gate
# (local feed: pack analyzer + ReadyLib + hard consumer asserts).
#
# Standalone satellite: place FSharp.PureAnalyzer*.nupkg in a local feed first
# (see README), or run the monorepo gate from a full fspure checkout.
set -euo pipefail

SAMPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONOREPO="$(cd "$SAMPLE_ROOT/../.." && pwd)"

if [[ -f "$MONOREPO/scripts/fspure-ready-lib-gate.sh" \
   && -f "$MONOREPO/FSharp.PureAnalyzer/FSharp.PureAnalyzer.fsproj" ]]; then
  echo "==> Monorepo detected — running scripts/fspure-ready-lib-gate.sh"
  exec bash "$MONOREPO/scripts/fspure-ready-lib-gate.sh"
fi

echo "ERROR: not inside the fspure monorepo." >&2
echo "  From a full checkout:  bash scripts/fspure-ready-lib-gate.sh" >&2
echo "  Or:                    bash e2e/ready-lib/run.sh" >&2
exit 1
