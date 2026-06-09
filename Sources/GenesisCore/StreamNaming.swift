import Foundation

/// Single source of truth for the event-stream CATEGORY PREFIX of a generated context.
///
/// The aggregate write category is `"<prefix><AggregateName>"` (AggregateRenderer / Aggregate.swift.template),
/// which KurrentDB exposes as the system category stream `$ce-<prefix><AggregateName>`. The read side MUST align
/// to that physical write category: the codegen'd JS projection subscribes `fromStreams(["$ce-<prefix><Agg>"])`
/// and the Presenter's `categoryRule` uses `.fromClass(withPrefix: "<prefix>_")`.
///
/// Before this type the prefix was derived two DIFFERENT ways — AggregateRenderer used the uppercase letters of
/// the contextName, while ReadModelRenderer used an `Opportunity→OC` alias else `upperSnake`. They only coincided
/// for `OpportunityContext`, so every other context's reads silently broke: the JS subscribed to a `$ce-` stream
/// the aggregate never wrote to, leaving the read model permanently empty. `StreamNaming` collapses both onto the
/// aggregate's existing write-category derivation (the physical truth — events land there), so all three sites
/// align by construction.
///
/// Canonical rule: prefix = the uppercase letters of the FULL contextName (`OpportunityContext → "OC"`,
/// `IAMContext → "IAMC"` — the trailing `C` of `IAMC` comes from the `C` in `Context`). This reproduces OC's
/// hand-written `"OC\(Self.self)"` category. The prefix is intentionally a lossy acronym (`AccountContext` and
/// `AdminContext` both → `"AC"`); acceptable because a Genesis project is single-context and the prefix only needs
/// to be self-consistent within one event-store namespace. (Multi-context-per-KDB would need hardening — future.)
public enum StreamNaming {

    /// Uppercase-letter category prefix of the FULL contextName. Throws on the degenerate `"Context"`-alone name
    /// (preserving ReadModelRenderer.streamPrefix's original contract) and on any all-lowercase name.
    public static func categoryPrefix(contextName: String) throws -> String {
        // Preserve the pre-existing "must not equal 'Context' alone" guard: uppercaseLetters("Context") == "C"
        // is non-empty, so the no-uppercase guard below would NOT catch it — check the stripped suffix explicitly.
        let strippedOfSuffix = contextName.hasSuffix("Context")
            ? String(contextName.dropLast("Context".count))
            : contextName
        if strippedOfSuffix.isEmpty {
            throw GenesisError.bundleInvalid(
                reason: "contextName must not equal 'Context' alone; cannot derive stream prefix"
            )
        }
        let letters = String(contextName.filter { $0.isUppercase })
        if letters.isEmpty {
            throw GenesisError.bundleInvalid(
                reason: "contextName '\(contextName)' has no uppercase letters to derive a stream category prefix; rename e.g. FooContext"
            )
        }
        return letters
    }

    /// Prefix used by the projection link stream + Presenter `categoryRule`: `"<categoryPrefix>_"`.
    public static func projectionPrefix(contextName: String) throws -> String {
        try categoryPrefix(contextName: contextName) + "_"
    }

    /// Source category = `categoryPrefix`; the JS projection subscribes `$ce-<sourceCategory><Aggregate>`.
    public static func sourceCategory(contextName: String) throws -> String {
        try categoryPrefix(contextName: contextName)
    }
}
