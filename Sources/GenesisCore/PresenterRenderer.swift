import Foundation

/// Phase 1.k: PresenterRenderer — read-side AS scaffold codegen.
/// Phase 1.k.2: routing by readModel.aggregateRef via `PresenterPlacementResolver` (audit M3).
///
/// Pure function of bundle. Emits read-side `<presenter.name>ApplicationService.swift`:
///   - per-aggregate placement → `Sources/<A>Aggregate/Adapter/<presenter.name>/...`
///   - context-level placement → `Sources/<contextName>/Adapter/<presenter.name>/...`
///
/// D1 (BundleParser) guarantees `presenter.aggregateRef` matches the resolved readModel
/// aggregateRef, so routing decision is unambiguous here.
public enum PresenterRenderer {

    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)] {
        var outputs: [(String, String, String)] = []
        let sharedImport = "import \(contextName)Shared"

        for (presenter, placement) in PresenterPlacementResolver.placements(bundle: bundle) {
            let basePath: String
            let aRef: String          // {A} template var (used for {A}QueryError reference)
            let projectorRefPath: String

            switch placement {
            case .aggregate(let aggName):
                // Defensive: must exist in bundle.aggregates[].
                guard bundle.aggregates.contains(where: { $0.name == aggName }) else { continue }
                basePath = "Sources/\(aggName)Aggregate/Adapter"
                aRef = aggName
                projectorRefPath = "Sources/\(aggName)Aggregate/Usecase/Projector/"
            case .context:
                basePath = "Sources/\(contextName)/Adapter"
                aRef = contextName
                projectorRefPath = "Sources/\(contextName)/Projector/"
            }

            let path = "\(basePath)/\(presenter.name)/\(presenter.name)ApplicationService.swift"
            if existingPaths.contains(path) { continue }  // scaffold-once

            let content = try renderApplicationService(
                presenter: presenter,
                sharedImport: sharedImport,
                aRef: aRef,
                projectorRefPath: projectorRefPath
            )
            outputs.append((path, content, "presenterApplicationService"))
        }
        return outputs
    }

    // MARK: - Helpers

    /// Compute the Output type string from `presenter.output`.
    public static func outputType(for output: PresenterOutput) -> String {
        switch output.kind {
        case .array:
            return "[\(output.elementType)]"
        case .single, .scalar:
            return output.isOptional ? "\(output.elementType)?" : output.elementType
        }
    }

    private static func renderApplicationService(
        presenter: PresenterSpec,
        sharedImport: String,
        aRef: String,
        projectorRefPath: String
    ) throws -> String {
        let template = try TemplateLoader.loadTemplate(name: "Api/PresenterApplicationService.swift", ext: "template")

        let fields = presenter.input.fields.map {
            PresenterInputField(
                name: $0.name,
                type: SwiftTypeResolver.translateNotation(rawType: $0.type),
                fromPath: $0.fromPath
            )
        }
        let inputFields: String = fields
            .map { "    package let \($0.name): \($0.type)" }
            .joined(separator: "\n")
        let initParams: String = fields
            .map { "\($0.name): \($0.type)" }
            .joined(separator: ", ")
        let initAssignments: String = fields
            .map { "        self.\($0.name) = \($0.name)" }
            .joined(separator: "\n")

        let outputT = outputType(for: presenter.output)

        return TemplateRenderer.render(template: template, vars: [
            "SharedImport": sharedImport,
            "Name": presenter.name,
            "A": aRef,
            "ProjectorRefPath": projectorRefPath,
            "INPUT_FIELDS": inputFields,
            "INIT_PARAMS": initParams,
            "INIT_ASSIGNMENTS": initAssignments,
            "OUTPUT_TYPE": outputT,
            "ElementSource": presenter.output.elementSource,
        ]).output
    }
}
