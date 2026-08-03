module Consumer

open Fspure.ReadyLib

/// Pure only when Fspure.ReadyLib's embedded pure.json marks Api.add as pure.
let useAdd (x: int) = Api.add x 1

/// Pure via library mapDouble / foundational List.map.
let useMap (xs: int list) = Api.mapDouble xs

/// Impure: calls library I/O.
let useImpure () = Api.impureLog "consumer"

/// Foundational pure still works without library embeds.
let useFoundational (xs: int list) = List.map (fun n -> n + 1) xs

[<EntryPoint>]
let main _ =
    ignore (useAdd 2)
    ignore (useMap [ 1; 2; 3 ])
    useImpure ()
    ignore (useFoundational [ 0 ])
    0
