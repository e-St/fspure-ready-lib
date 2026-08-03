namespace Fspure.ReadyLib

/// Public surface used by consumers and by the sample consumer test project.
///
/// Deliberately pure helpers are intended to land in the collected pure.json.
/// The impure helper must stay impure (I/O) so vanilla fspure labels it correctly.
module Api =

    // --- Pure (collector should classify as pure) ---

    /// Integer addition.
    let add (x: int) (y: int) : int = x + y

    /// Integer multiplication.
    let mul (x: int) (y: int) : int = x * y

    /// Absolute value without branching on effects.
    let absInt (x: int) : int = if x < 0 then -x else x

    /// Clamp to an inclusive range (pure arithmetic / comparison).
    let clamp (lo: int) (hi: int) (x: int) : int =
        if x < lo then lo
        elif x > hi then hi
        else x

    /// Map a list of ints with a pure transformation (List.map is foundational pure).
    let mapDouble (xs: int list) : int list = List.map (fun n -> n * 2) xs

    /// Fold a sum (pure).
    let sum (xs: int list) : int = List.fold (fun acc n -> acc + n) 0 xs

    // --- Escape hatch (pure only via pure-extra.json merge) ---

    /// Intentionally not discoverable as pure by IL alone in all cases;
    /// pure-extra.json claims it so maintainers can see the merge path.
    let manualEscapeHatch (x: int) : int = x ^^^ 0

    // --- Impure (must remain impure) ---

    /// Side-effecting log — must NOT appear as pure in pure.json.
    let impureLog (message: string) : unit =
        System.Console.WriteLine(message)
