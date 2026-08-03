# Operating this as a separate GitHub repository

This document is for **you** (the maintainer of `fspure-ready-lib`).

## Source of truth (monorepo control)

**Do not treat this clone as the place to edit the sample long-term.**

| Role | Repository | Path |
|------|------------|------|
| **Source of truth** | [e-St/fspure](https://github.com/e-St/fspure) | `samples/fspure-ready-lib/` |
| **Public satellite** | [e-St/fspure-ready-lib](https://github.com/e-St/fspure-ready-lib) | repo root |

The monorepo workflow **Sync fspure-ready-lib** updates this repo with **one synthetic commit** per sync (`sync from e-St/fspure@…`). That **push** still triggers **this** repo’s GitHub Actions (CI, pack, etc.).

Full setup (PAT secret):  
**https://github.com/e-St/fspure/blob/main/docs/SYNC-FSPURE-READY-LIB.md**

After each sync, see **`.fspure-sync-source`** for the monorepo commit SHA.

## One-time bootstrap (if the satellite was empty)

```bash
# From a fspure checkout:
cd samples/fspure-ready-lib
# Option A: let the monorepo workflow push after you set FSPURE_READY_LIB_PUSH_TOKEN
# Option B: manual first push
git init -b main
git add .
git commit -m "Initial commit: fspure-ready-lib sample"
gh repo create e-St/fspure-ready-lib --public --source=. --remote=origin --push
```

## Secrets (repository settings)

| Secret | Used by | Purpose |
|--------|---------|---------|
| `NUGET_API_KEY` | `publish.yml` → nuget.org | Publish `Fspure.ReadyLib` |
| (auto) `GITHUB_TOKEN` | `publish.yml` → GitHub Packages | Publish to `nuget.pkg.github.com/e-St` |

## CI expectations

Workflow **CI** must be able to restore **`FSharp.PureAnalyzer`** (with Phase 3 embed targets) from:

- nuget.org (preferred once published), or  
- workflow_dispatch input `fspure_analyzer_source` + version override  

Until Phase 3 lands on nuget.org, run CI with a pre-seeded feed:

1. Pack FSharp.PureAnalyzer from monorepo  
2. Host the nupkg on GitHub Packages or a temporary feed  
3. Pass that source into the workflow_dispatch input  

## Versioning

| Package | Suggested version |
|---------|-------------------|
| `Fspure.ReadyLib` | `0.1.0-preview.N` until stable |
| `FSharp.PureAnalyzer` | pin exactly (e.g. `0.1.0`) in `Directory.Packages.props` |

## What not to put in this repo

- Do not vendor purity-collector source or the full fspure monorepo  
- Do not set `PrivateAssets` incorrectly on FSharp.PureAnalyzer (must be `all` on the library)  
- Do not target net8/net9 — **net10.0 only**  

## Sync strategy with monorepo

When MSBuild targets or pure.json schema change in fspure:

1. Bump `FspureAnalyzerVersion` here  
2. Re-run CI  
3. Publish a new `Fspure.ReadyLib` prerelease if the public story changed  
