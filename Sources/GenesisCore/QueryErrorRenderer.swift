import Foundation

/// Phase 1.k.2: emit `{A}QueryError.swift` (per-aggregate) + `{Context}QueryError.swift` (context-level)
/// for read-side `notFound` error semantics. Pure function of bundle; scaffold-once via `existingPaths`
/// (audit M4) so user-extended cases survive regeneration.
public enum QueryErrorRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)] {
        let template = try TemplateLoader.loadTemplate(name: "QueryError.swift", ext: "template")
        let sharedImport = "import \(contextName)Shared"

        var outputs: [(String, String, String)] = []

        // Per-aggregate: emit {A}QueryError.swift for each aggregate that has at least one read presenter.
        let aggsWithRead = PresenterPlacementResolver.aggregatesWithReadPresenter(bundle: bundle)
        for aggregate in bundle.aggregates where aggsWithRead.contains(aggregate.name) {
            let path = "Sources/\(aggregate.name)Aggregate/\(aggregate.name)QueryError.swift"
            if existingPaths.contains(path) { continue }  // scaffold-once
            let content = TemplateRenderer.render(
                template: template,
                vars: [
                    "SharedImport": sharedImport,
                    "QueryErrorTypeName": "\(aggregate.name)QueryError",
                ]
            ).output
            outputs.append((path, content, "queryError"))
        }

        // Context-level: emit {Context}QueryError.swift when bundle has context-level presenter.
        if PresenterPlacementResolver.hasContextLevelPresenter(bundle: bundle) {
            let path = "Sources/\(contextName)/\(contextName)QueryError.swift"
            if !existingPaths.contains(path) {
                let content = TemplateRenderer.render(
                    template: template,
                    vars: [
                        "SharedImport": sharedImport,
                        "QueryErrorTypeName": "\(contextName)QueryError",
                    ]
                ).output
                outputs.append((path, content, "queryError"))
            }
        }

        return outputs
    }
}
