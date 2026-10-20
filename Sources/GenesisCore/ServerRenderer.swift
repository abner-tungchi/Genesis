import Foundation

/// Phase 1.m: emit `Sources/<ContextName>Server/<ContextName>Server.swift` (HTTP MVP only).
///
/// Pure function of bundle. Only emit when bundle has at least one handler (per-agg write UC,
/// per-agg read presenter, or context-level presenter); otherwise return [] (no Server target).
///
/// Per audit H1: target deps emit DDDKit/Hummingbird/OpenAPIHummingbird/OpenAPIRuntime/Logging products;
/// **不** emit Foundation 或 explicit KurrentDB（透過 DDDKit/KurrentSupport 傳遞性提供）。
public enum ServerRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)] {
        let aggregatesWithHandler = aggregatesNeedingHandler(bundle: bundle)
        let hasContextPresenter = PresenterPlacementResolver.hasContextLevelPresenter(bundle: bundle)

        // No handler at all → no Server target
        guard !aggregatesWithHandler.isEmpty || hasContextPresenter else { return [] }

        let path = "Sources/\(contextName)Server/\(contextName)Server.swift"
        if existingPaths.contains(path) { return [] }  // scaffold-once

        let template = try TemplateLoader.loadTemplate(name: "Server/Server.swift", ext: "template")

        // import <A>Aggregate per handler-bearing aggregate (sorted by name for stability)
        let aggregateImports = aggregatesWithHandler
            .map { "import \($0.name)Aggregate" }
            .sorted()
            .joined(separator: "\n")

        // import <contextName> (context module) when context-level handler exists
        let contextImport = hasContextPresenter ? "import \(contextName)" : ""

        // disambiguating handler imports: `import struct <Module>.ApiHandler`
        // — both per-agg and context-level handler types share the same name `ApiHandler` (Phase 1.i/1.k.2)
        var handlerImports: [String] = []
        for agg in aggregatesWithHandler.sorted(by: { $0.name < $1.name }) {
            handlerImports.append("import struct \(agg.name)Aggregate.ApiHandler")
        }
        if hasContextPresenter {
            handlerImports.append("import struct \(contextName).ApiHandler")
        }

        // handler registrations: 8-space indent (inside `main()` body)
        var registrations: [String] = []
        for agg in aggregatesWithHandler.sorted(by: { $0.name < $1.name }) {
            registrations.append("        try \(agg.name)Aggregate.ApiHandler(kdbClient: kdbClient)\n            .registerApiHandlers(on: router, serverURL: serverURL, middlewares: [])")
        }
        if hasContextPresenter {
            registrations.append("        try \(contextName).ApiHandler(kdbClient: kdbClient)\n            .registerApiHandlers(on: router, serverURL: serverURL, middlewares: [])")
        }

        let content = TemplateRenderer.render(template: template, vars: [
            "ContextName": contextName,
            "AggregateImports": aggregateImports,
            "ContextImport": contextImport,
            "HandlerImports": handlerImports.joined(separator: "\n"),
            "HandlerRegistrations": registrations.joined(separator: "\n"),
        ]).output

        return [(path, content, "server")]
    }

    /// Aggregates that have either a write UC (Phase 1.i ApiHandler emit condition)
    /// or a per-aggregate read presenter (Phase 1.k extension).
    /// Matches ApiHandlerRenderer's per-aggregate emit condition.
    static func aggregatesNeedingHandler(bundle: FullBundle) -> [AggregateSpec] {
        bundle.aggregates.filter { agg in
            let hasWriteUC = bundle.useCases.contains {
                $0.aggregateSpecId == agg.aggregateSpecId && !ApiRenderer.isReadUseCase($0.useCase)
            }
            let hasReadPresenter = bundle.presenters.contains { $0.aggregateRef == agg.name }
            return hasWriteUC || hasReadPresenter
        }
    }
}
