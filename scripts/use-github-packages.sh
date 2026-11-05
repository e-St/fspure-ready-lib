#!/usr/bin/env bash
# Configure NuGet auth for https://nuget.pkg.github.com/e-St/index.json
#
# Env:
#   GITHUB_TOKEN or GH_TOKEN  — PAT / Actions token with read:packages (or packages:read)
#   GITHUB_ACTOR              — username (defaults to x-access-token / github-actions)
#
# Usage (from repo root):
#   export GITHUB_TOKEN=...
#   source scripts/use-github-packages.sh   # or bash scripts/use-github-packages.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/NuGet.Config"
# Prefer a packages-read PAT that can see packages published by e-St/fspure
# (GITHUB_TOKEN from fspure-ready-lib cannot download those by default).
TOKEN="${FSPURE_PACKAGES_READ_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
USER="${GITHUB_ACTOR:-x-access-token}"

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: set GITHUB_TOKEN or FSPURE_PACKAGES_READ_TOKEN (packages:read) for e-St GitHub Packages." >&2
  exit 1
fi

# Remove then re-add so credentials are always current (CI tokens rotate).
dotnet nuget remove source github-e-st --configfile "$CONFIG" >/dev/null 2>&1 || true
dotnet nuget add source "https://nuget.pkg.github.com/e-St/index.json" \
  --name github-e-st \
  --username "$USER" \
  --password "$TOKEN" \
  --store-password-in-clear-text \
  --configfile "$CONFIG"

echo "OK: NuGet source github-e-st authenticated as ${USER}"
