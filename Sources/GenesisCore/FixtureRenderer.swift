import Foundation

/// Codegen the bare per-aggregate test fixture wrappers (the `UsecaseCall` helpers) that test-gen's Lane-B
/// Givens and the invariant-TDD loop depend on. Per the fixture-codegen-vs-skill consensus (D1:
/// deterministic → codegen): a bare single-UC wrapper is a pure function of `useCase.input` / aggregate /
/// verb / identityName, so it is rendered HERE, not authored by a `/fixture-gen` skill.
///
/// One file per aggregate at `Tests/<Ctx>Tests/SharedUtility/UsecaseCall/<A>.swift` (OC parity), role
/// `"fixture"`, regenerated wholesale. Each wrapper is BARE — every param required, ZERO defaults (a default
/// would smuggle a "which invariants are reachable" decision); ergonomic presets live in a human-owned sibling
/// `<A>Fixtures.presets.swift` that Genesis never generates or overwrites (a header comment signposts this).
///
/// The wrapper is a uniform one-liner around `<UC>Service(repository:).execute(input:)` — a REAL execute
/// (R-SUT red until /domain-fill), identical for create/update/delete because the dispatch already lives in
/// the codegen'd `execute()` body. The `.init(...)` arg order matches `<UC>Input.init` BY CONSTRUCTION via the
/// shared `UseCaseRenderer.canonicalInputFields`. Read-side queries are auto-excluded (they live in
/// `bundle.readModels`, not `bundle.useCases`). The fixture is invisible to `genesis verify` FIX-2 (it is a
/// real `execute` call in `@Test`-free `SharedUtility` preamble, not a `genesisTODO(` arrange-thunk).
public enum FixtureRenderer {
    public static func render(
        bundle: FullBundle,
        adapter: Adapter,
        contextName: String
    ) throws -> [(path: String, content: String, role: String)] {
        // Mirror UseCaseRenderer's type-resolution inputs so resolved fixture param types match <UC>Input.
        let knownCustomTypes = bundle.dtoTypeNames.union(adapter.customTypes.map { $0.name })
        // sharedImport: verbatim mirror of AggregateRenderer's CONDITIONAL derivation — present only when the
        // context has DTOs or adapter custom types (an unused such import is harmless).
        let sharedImport = (!bundle.dtos.isEmpty || !adapter.customTypes.isEmpty)
            ? "import \(contextName)Shared"
            : ""

        var outputs: [(String, String, String)] = []

        for aggregate in bundle.aggregates {
            let ucs = bundle.useCases.filter { $0.aggregateSpecId == aggregate.aggregateSpecId }
            guard !ucs.isEmpty else { continue }  // no use cases → no fixture file

            var funcs: [String] = []
            for uc in ucs {
                let ucName = CaseTransformer.upperCamel(uc.useCase)
                let ucCamel = CaseTransformer.lowerCamel(uc.useCase)
                let canonical = UseCaseRenderer.canonicalInputFields(
                    fields: uc.input, aggIdName: aggregate.identityName
                )
                var params: [String] = []
                var initArgs: [String] = []
                for field in canonical {
                    let resolved = try SwiftTypeResolver.resolve(
                        rawType: field.rawType, knownCustomTypes: knownCustomTypes, adapter: adapter
                    )
                    params.append("\(field.name): \(resolved)")
                    initArgs.append("\(field.name): \(field.name)")
                }
                params.append("repository: \(aggregate.name)Repository")
                funcs.append("""
                @discardableResult
                func \(ucCamel)(\(params.joined(separator: ", "))) async throws -> String? {
                    let output = try await \(ucName)Service(repository: repository).execute(input: .init(\(initArgs.joined(separator: ", "))))
                    return output.id
                }
                """)
            }

            var lines: [String] = [header(aggName: aggregate.name), "import Foundation", "import \(aggregate.name)Aggregate"]
            if !sharedImport.isEmpty { lines.append(sharedImport) }
            lines.append("")
            lines.append(funcs.joined(separator: "\n\n"))
            lines.append("")
            let content = lines.joined(separator: "\n")
            let path = "Tests/\(contextName)Tests/SharedUtility/UsecaseCall/\(aggregate.name).swift"
            outputs.append((path, content, "fixture"))
        }

        return outputs
    }

    /// Header signpost (D3): because Genesis emits NO preset stub (user decision), this header is the SOLE
    /// place that tells the human "defaults/presets go in a sibling, never on the bare wrapper".
    private static func header(aggName: String) -> String {
        """
        // GENESIS-GENERATED — regenerated wholesale by `genesis new`. Do NOT edit, and do NOT add defaults or
        // presets here: a default value (e.g. status = .established) silently smuggles a "which invariants are
        // reachable" decision into an ergonomic helper. For ergonomic defaults/presets, create a human-owned
        // sibling `\(aggName)Fixtures.presets.swift` (named overloads delegating to these bare wrappers);
        // Genesis never generates or overwrites that file.
        """
    }
}
