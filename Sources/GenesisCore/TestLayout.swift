import Foundation

/// Single source of truth for GENERATED-PROJECT test-file paths.
///
/// Before this deriver the path convention was duplicated and ALREADY drifted: `FixtureRenderer` emitted a
/// deep `Tests/<Ctx>Tests/SharedUtility/UsecaseCall/<A>.swift` while the test-gen SKILL prose emitted a FLAT
/// `Tests/<Ctx>Tests/<ucPascal>Tests.generated.swift`. `TestLayout` collapses every producer onto one
/// convention (OC AuditQuotingAggregate parity: aggregate-scoped `Usecases/` + `Api/` nesting, layer-suffixed
/// filenames `UsecaseTests` / `ApiTests`).
///
/// The Swift caller (`FixtureRenderer`) interpolates these templates — compile-locked. The test-gen + api
/// lanes are emitted by an LLM SKILL (prose), which cannot call Swift at skill-runtime; so the path TEMPLATES
/// below are the authoritative strings and the SKILL.md prose mirrors them VERBATIM. `TestLayoutTests`
/// drift-guards that mirror: it asserts the test-gen `SKILL.md` resource contains each template byte-for-byte
/// (and that the OLD flat path token is gone). The placeholder tokens (`<contextName>`/`<A>`/`<ucPascal>`) are
/// deliberately identical to the SKILL's own tokens so the `contains(...)` guard is robust.
public enum TestLayout {
    // MARK: - Path templates (the single source; SKILL.md prose MUST contain these verbatim)

    public static let usecaseGeneratedTemplate = "Tests/<contextName>Tests/<A>Aggregate/Usecases/<ucPascal>/<ucPascal>UsecaseTests.generated.swift"
    public static let usecaseAuthoredTemplate  = "Tests/<contextName>Tests/<A>Aggregate/Usecases/<ucPascal>/<ucPascal>UsecaseTests.authored.swift"
    public static let apiGeneratedTemplate     = "Tests/<contextName>Tests/<A>Aggregate/Api/<ucPascal>/<ucPascal>ApiTests.generated.swift"
    public static let apiAuthoredTemplate      = "Tests/<contextName>Tests/<A>Aggregate/Api/<ucPascal>/<ucPascal>ApiTests.authored.swift"
    /// Cross-UC fixture file (per aggregate, not per UC) — already OC-aligned; unchanged, now sourced here.
    public static let fixtureTemplate          = "Tests/<contextName>Tests/SharedUtility/UsecaseCall/<A>.swift"
    /// Shared test-support file (one per context, at the test-target root).
    public static let supportTemplate          = "Tests/<contextName>Tests/GenesisTestSupport.swift"

    public enum Layer { case usecase, api }
    public enum FileKind { case generated, authored }

    // MARK: - Concrete-path derivation (Swift callers)

    /// Per-UC test path for a `(layer, file)` pair. `ucPascal` is the UpperCamel use-case name
    /// (`CaseTransformer.upperCamel(useCase)`); the deriver does NOT case-transform — it only assembles the path.
    public static func testPath(
        contextName: String,
        aggregateName: String,
        ucPascal: String,
        layer: Layer,
        file: FileKind
    ) -> String {
        let template: String
        switch (layer, file) {
        case (.usecase, .generated): template = usecaseGeneratedTemplate
        case (.usecase, .authored):  template = usecaseAuthoredTemplate
        case (.api, .generated):     template = apiGeneratedTemplate
        case (.api, .authored):      template = apiAuthoredTemplate
        }
        return fill(template, contextName: contextName, aggregateName: aggregateName, ucPascal: ucPascal)
    }

    public static func fixturePath(contextName: String, aggregateName: String) -> String {
        fill(fixtureTemplate, contextName: contextName, aggregateName: aggregateName, ucPascal: "")
    }

    public static func supportPath(contextName: String) -> String {
        fill(supportTemplate, contextName: contextName, aggregateName: "", ucPascal: "")
    }

    // Replacement order is safe: none of the placeholder VALUES can contain another placeholder TOKEN, and the
    // literal token "<contextName>" does not contain "<A>" or "<ucPascal>".
    private static func fill(_ template: String, contextName: String, aggregateName: String, ucPascal: String) -> String {
        template
            .replacingOccurrences(of: "<contextName>", with: contextName)
            .replacingOccurrences(of: "<A>", with: aggregateName)
            .replacingOccurrences(of: "<ucPascal>", with: ucPascal)
    }
}
