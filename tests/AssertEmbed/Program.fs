// Assert that a managed assembly embeds {AssemblyName}.pure.json and (optionally)
// contains expected pure method full names. Used by CI after pack/build.
//
// Usage:
//   dotnet run --project tests/AssertEmbed -- <path-to.dll> [expectedMethod ...]
//
// Exit 0 on success; non-zero with a clear message on failure.

module AssertEmbed

open System
open System.IO
open System.Reflection
open System.Reflection.Metadata
open System.Reflection.PortableExecutable
open System.Text
open System.Text.Json

let private fail msg =
    eprintfn "ERROR: %s" msg
    1

let private tryReadEmbeddedPureJson (assemblyPath: string) : Result<string * string, string> =
    try
        use stream = File.OpenRead assemblyPath
        use pe = new PEReader(stream, PEStreamOptions.PrefetchEntireImage)

        if not pe.HasMetadata then
            Error "assembly has no metadata"
        else
            let md = pe.GetMetadataReader()
            let asmName = md.GetString(md.GetAssemblyDefinition().Name)
            let expected = asmName + ".pure.json"

            let mutable found: (string * byte[]) option = None

            for handle in md.ManifestResources do
                let resource = md.GetManifestResource handle
                let name = md.GetString resource.Name

                if
                    name.Equals(expected, StringComparison.OrdinalIgnoreCase)
                    || name.EndsWith(".pure.json", StringComparison.OrdinalIgnoreCase)
                then
                    if resource.Implementation.IsNil then
                        match pe.PEHeaders.CorHeader with
                        | null -> ()
                        | cor when cor.ResourcesDirectory.RelativeVirtualAddress = 0 -> ()
                        | cor ->
                            let block = pe.GetSectionData(cor.ResourcesDirectory.RelativeVirtualAddress)
                            let offset = int resource.Offset

                            if offset >= 0 && offset < block.Length then
                                let br = block.GetReader(offset, block.Length - offset)
                                let len = br.ReadInt32()

                                if len >= 0 && len <= br.RemainingBytes then
                                    found <- Some(name, br.ReadBytes len)

            match found with
            | None -> Error $"no embedded *.pure.json resource (expected '{expected}')"
            | Some(name, bytes) -> Ok(name, Encoding.UTF8.GetString bytes)
    with ex ->
        Error ex.Message

[<EntryPoint>]
let main argv =
    if argv.Length < 1 then
        fail "usage: AssertEmbed <assembly.dll> [expectedFullName ...]"
    else
        let path = Path.GetFullPath argv.[0]

        if not (File.Exists path) then
            fail $"file not found: {path}"
        else
            match tryReadEmbeddedPureJson path with
            | Error e -> fail e
            | Ok(resourceName, json) ->
                printfn "OK resource: %s (%d chars)" resourceName json.Length

                use doc = JsonDocument.Parse(json)
                let root = doc.RootElement

                match root.TryGetProperty "schemaVersion" with
                | true, v when v.GetString() = "1.0" -> printfn "OK schemaVersion: 1.0"
                | _ ->
                    eprintfn "ERROR: schemaVersion must be \"1.0\""
                    exit 1

                let methods =
                    match root.TryGetProperty "pureMethods" with
                    | true, arr when arr.ValueKind = JsonValueKind.Array ->
                        arr.EnumerateArray()
                        |> Seq.choose (fun m ->
                            match m.TryGetProperty "fullName" with
                            | true, n ->
                                match n.GetString() with
                                | null
                                | "" -> None
                                | s -> Some s
                            | _ -> None)
                        |> Set.ofSeq
                    | _ -> Set.empty

                printfn "OK pureMethods: %d" methods.Count

                let expected = argv |> Array.skip 1 |> Array.toList
                let mutable missing = []

                for name in expected do
                    if not (Set.contains name methods) then
                        missing <- name :: missing

                if not missing.IsEmpty then
                    eprintfn "ERROR: missing pure methods:"
                    for m in List.rev missing do
                        eprintfn "  - %s" m

                    eprintfn "sample present:"

                    methods
                    |> Seq.truncate 20
                    |> Seq.iter (fun m -> eprintfn "  + %s" m)

                    1
                else
                    for name in expected do
                        printfn "OK method: %s" name

                    0
