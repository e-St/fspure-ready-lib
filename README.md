# fspure-ready-lib

Minimal **net10.0** F# library that is **fspure-ready**: building the package embeds a `pure.json` pure-method whitelist into the DLL so vanilla fspure users (FSharp.PureAnalyzer + VS Code decorations) get correct pure/impure labels when they call your API.

This repository is the public, copy-paste template for library authors.

| | |
|--|--|
| **Package** | `Fspure.ReadyLib` |
| **TFM** | `net10.0` only |
| **fspure stack** | [e-St/fspure](https://github.com/e-St/fspure) · FSharp.Analyzers.SDK **0.35** |

---

## The one-liner (what maintainers actually need)

In your **library** project (or `Directory.Build.props`):

```xml
<ItemGroup>
  <PackageReference Include="FSharp.PureAnalyzer" Version="0.1.0" PrivateAssets="all" />
</ItemGroup>
```

That single reference pulls MSBuild targets that, after each build:

1. Run **purity-collector** on your DLL  
2. Merge optional **`pure-extra.json`** next to the project  
3. Embed **`{AssemblyName}.pure.json`** into the DLL  

`PrivateAssets="all"` keeps the analyzer out of **your** package graph so app authors are not forced to take it transitively.

Optional escape hatch (this repo demonstrates it):

```text
src/YourLib/pure-extra.json   # merge author-claimed pure methods
```

Opt out for a project:

```xml
<FspureEmbedPureJson>false</FspureEmbedPureJson>
```

---

## Badges (what consumers see with fspure vanilla)

| Library API | Expected label | Why |
|-------------|----------------|-----|
| `Api.add`, `Api.mul`, `Api.absInt`, `Api.clamp`, `Api.mapDouble`, `Api.sum` | **pure** | Collected into embedded pure.json |
| `Api.manualEscapeHatch` | **pure** | Claimed via `pure-extra.json` merge |
| `Api.impureLog` | **impure** | Console I/O |

Consumer wrappers that only call pure library APIs should get **PURE003**; wrappers that call `impureLog` should get **PURE002**.

---

## Layout

```text
src/Fspure.ReadyLib/     # the publishable class library
  Library.fs
  pure-extra.json        # merge demo
  Fspure.ReadyLib.fsproj
tests/AssertEmbed/       # PE reader: assert embedded pure.json
tests/Consumer/          # restores packed package; used with fsharp-analyzers
scripts/                 # CI helpers
.github/workflows/       # CI + optional publish
Directory.Build.props    # turns embed on for the library
```

---

## Local development

**Prerequisites:** .NET **10** SDK, network access to nuget.org (for `FSharp.PureAnalyzer`).

```bash
# From this repository root
dotnet tool restore

# Pack the sample library into artifacts/packages
# (requires FSharp.PureAnalyzer on nuget.org or a configured feed)
export FspureAnalyzerVersion=0.1.0   # override if needed
bash scripts/ci-build-and-assert.sh
```

Point at a **local** FSharp.PureAnalyzer nupkg (e.g. built from the monorepo):

```bash
mkdir -p artifacts/packages
# copy FSharp.PureAnalyzer.*.nupkg into artifacts/packages (or another folder listed in NuGet.Config)
dotnet nuget add source "$(pwd)/artifacts/packages" --name local-fspure --configfile NuGet.Config
export FspureAnalyzerVersion=0.1.0
bash scripts/ci-build-and-assert.sh
```

---

## Publishing a prerelease (you manage this repo)

1. Ensure **FSharp.PureAnalyzer** with Phase 3 targets is available on nuget.org or GitHub Packages.  
2. In this repo: **Actions → Publish prerelease → Run workflow**.  
3. Choose version (`0.1.0-preview.N`), analyzer version, and destination (`github` / `nuget.org` / `both`).  
4. Secrets (on **this** repository):
   - `NUGET_API_KEY` — nuget.org (if publishing there)
   - `GITHUB_TOKEN` — automatic for GitHub Packages  

Package id: **`Fspure.ReadyLib`**.

Consumers:

```bash
dotnet add package Fspure.ReadyLib --version 0.1.0-preview.1
```

App authors who want labels also install fspure vanilla:

```bash
dotnet add package FSharp.PureAnalyzer
# + VS Code extension: fsharp-pure-decorations (Open VSX)
```

---

## How to create the GitHub repository from this tree

This folder is designed as the **root** of a standalone repo (e.g. `https://github.com/e-St/fspure-ready-lib`).

```bash
# From the fspure monorepo (or any checkout that contains samples/fspure-ready-lib)
cd samples/fspure-ready-lib

git init
git add .
git commit -m "Initial fspure-ready-lib sample (net10.0 + pure.json embed)"

# Create empty repo on GitHub (gh CLI), then:
gh repo create e-St/fspure-ready-lib --public --source=. --remote=origin --push
# or: git remote add origin git@github.com:e-St/fspure-ready-lib.git && git push -u origin main
```

Keep this sample in sync with fspure Phase 3+ as needed; it is intentionally small and dependency-light.

---

## Related

- Main infrastructure: [e-St/fspure](https://github.com/e-St/fspure)  
- Analyzer package: `FSharp.PureAnalyzer` (MSBuild targets + Ionide analyzer)  
- Collector tool: `purity-collector` (also bundled inside the analyzer package tools/)  
