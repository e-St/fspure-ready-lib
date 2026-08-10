#!/usr/bin/env bash
# Compare ReadyLib-owned pure methods in a pure.json (file or extracted from DLL)
# against tests/golden/Fspure.ReadyLib.pure-methods.golden.txt
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN="$ROOT/tests/golden/Fspure.ReadyLib.pure-methods.golden.txt"
SRC="${1:-}"

if [[ -z "$SRC" || ! -f "$SRC" ]]; then
  echo "usage: $0 <path-to.pure.json | path-to.dll>" >&2
  exit 2
fi

[[ -f "$GOLDEN" ]] || { echo "ERROR: golden missing: $GOLDEN" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if [[ "$SRC" == *.dll ]]; then
  # Prefer generated obj pure.json next to DLL if present; else AssertEmbed path via python PE is heavy —
  # require companion pure.json from build intermediate when given a DLL.
  PURE_JSON="$(dirname "$SRC")/Fspure.ReadyLib.pure.json"
  if [[ ! -f "$PURE_JSON" ]]; then
    # IntermediateOutputPath layout: bin/… vs obj/…
    CAND="$(find "$ROOT/src/Fspure.ReadyLib/obj" -name 'Fspure.ReadyLib.pure.json' 2>/dev/null | head -1 || true)"
    PURE_JSON="$CAND"
  fi
  [[ -n "$PURE_JSON" && -f "$PURE_JSON" ]] || {
    echo "ERROR: could not find Fspure.ReadyLib.pure.json for $SRC" >&2
    exit 1
  }
  SRC="$PURE_JSON"
fi

python3 - "$SRC" "$GOLDEN" <<'PY'
import json, sys
pure_path, golden_path = sys.argv[1], sys.argv[2]

with open(pure_path, encoding="utf-8") as f:
    doc = json.load(f)

methods = {
    m.get("fullName")
    for m in (doc.get("pureMethods") or [])
    if isinstance(m, dict) and m.get("fullName")
}
# Contract is only the sample's own API surface (ignore collector noise / foundational leaks).
ready = {n for n in methods if n.startswith("Fspure.ReadyLib.")}

expected = []
with open(golden_path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        expected.append(line)
expected_set = set(expected)

missing = sorted(expected_set - ready)
extra = sorted(ready - expected_set)

# impureLog must never be pure
if "Fspure.ReadyLib.Api.impureLog" in methods:
    print("ERROR: Api.impureLog must not appear in pure.json", file=sys.stderr)
    sys.exit(1)

if missing:
    print("ERROR: golden methods missing from pure.json:", file=sys.stderr)
    for m in missing:
        print(f"  - {m}", file=sys.stderr)
    sys.exit(1)

if extra:
    # Extra ReadyLib.* pure methods are allowed only if we choose strict equality.
    # Strict: any ReadyLib surface not in golden fails (catches accidental pure impureLog etc.).
    print("ERROR: ReadyLib pure methods not in golden (update golden if intentional):", file=sys.stderr)
    for m in extra:
        print(f"  + {m}", file=sys.stderr)
    sys.exit(1)

print(f"OK: golden pure methods match ({len(expected_set)} Fspure.ReadyLib.* names)")
print(f"    pure.json: {pure_path}")
print(f"    golden:    {golden_path}")
PY
