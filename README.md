# fspure-ready-lib

Minimal **net10.0** F# library that is **fspure-ready**: building the package embeds a `pure.json` pure-method whitelist into the DLL so vanilla fspure users (FSharp.PureAnalyzer + VS Code decorations) get correct pure/impure labels when they call your API.

This tree is the copy-paste template for library authors. Source of truth lives in the [fspure monorepo](https://github.com/e-St/fspure) under `samples/fspure-ready-lib/`.

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
  <PackageReference Include="FSharp.PureAnalyzer" Version="VERSION" PrivateAssets="all" />
</ItemGroup>
```

Use a `FSharp.PureAnalyzer` version that ships **MSBuild embed targets** (`build/FSharp.PureAnalyzer.targets` + `tools/purity-collector/`). That is the Phase 3+ package layout.

That single reference pulls targets that, after each build:

1. Run **purity-collector** on your DLL  
2. Merge optional **`pure-extra.json`** next to the project  
3. Embed **`{AssemblyName}.pure.json`** into the DLL  

`PrivateAssets="all"` keeps the analyzer out of **your** package graph so app authors are not forced to take it transitively.

Optional escape hatch (this sample demonstrates it):

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
| `Api.add`, `Api.mul`, `Api.absInt`, `Api.clamp` | **pure** | Collected into embedded pure.json |
| `Api.mapDouble`, `Api.sum`, `Api.manualEscapeHatch` | **pure** | Claimed via `pure-extra.json` merge (HOF / escape hatch) |
| `Api.impureLog` | **impure** | Console I/O |

Consumer wrappers that only call pure library APIs should get **PURE003**; wrappers that call `impureLog` should get **PURE002**.

---

## How CI proves this (local feed — the real gate)

**CI does not depend on nuget.org or GitHub Packages for the gate.**  
The monorepo builds both packages into a local NuGet feed and asserts the full story:

```text
pack FSharp.PureAnalyzer  →  artifacts/local-feed/
pack Fspure.ReadyLib      →  same feed (embeds pure.json)
consumer restores ReadyLib nupkg
fsharp-analyzers          →  hard-fail unless useAdd is PURE003 and useImpure is PURE002
```

From the **fspure monorepo root**:

```bash
bash scripts/fspure-ready-lib-gate.sh
# same entrypoint:
bash e2e/ready-lib/run.sh
# from this folder (when nested in monorepo):
bash scripts/ci-build-and-assert.sh
```

Workflow: `.github/workflows/fspure-ready-lib-gate.yml` on the monorepo.

Artifacts: `artifacts/local-feed/*.nupkg`, `artifacts/fspure-ready-lib-gate/` (SARIF + stdout).

Publishing packages to the internet is **optional** and is not required for a green gate.

---

## Layout

```text
src/Fspure.ReadyLib/     # the publishable class library
  Library.fs
  pure-extra.json        # merge demo
  Fspure.ReadyLib.fsproj
tests/AssertEmbed/       # PE reader: assert embedded pure.json
tests/Consumer/          # restores packed package; used with fsharp-analyzers
scripts/                 # thin wrappers → monorepo gate when nested
.github/workflows/       # satellite CI / optional publish (marketing)
Directory.Build.props    # turns embed on for the library
```

---

## Optional: publish a prerelease (not a CI gate)

When you want a public demo package:

1. Ensure **FSharp.PureAnalyzer** with embed targets is on nuget.org (or your feed).  
2. Pack and push `Fspure.ReadyLib` (satellite workflow **Publish prerelease**, or `dotnet nuget push` from monorepo `artifacts/local-feed/`).  
3. Consumers: `dotnet add package Fspure.ReadyLib --version …`

App authors who want labels still install fspure vanilla:

```bash
dotnet add package FSharp.PureAnalyzer
# + VS Code extension: fsharp-pure-decorations (Open VSX)
```

---

## Related

- Main infrastructure: [e-St/fspure](https://github.com/e-St/fspure)  
- Monorepo gate: `scripts/fspure-ready-lib-gate.sh` · `e2e/ready-lib/`  
- Analyzer package: `FSharp.PureAnalyzer` (MSBuild targets + Ionide analyzer)  
- Collector tool: `purity-collector` (bundled inside the analyzer package `tools/`)  
