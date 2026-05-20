import Foundation

/// Phase 1.i: ApiHandler.swift + ApiComponents+<A>ApiError.swift emission per aggregate
/// (only when aggregate has at least 1 write UC). Synchronous emit per Phase 1.h audit H4.
///
/// Pure function of bundle.
public enum ApiHandlerRenderer {

    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)] {
        var outputs: [(String, String, String)] = []
        let sharedImport = "import \(contextName)Shared"

        for aggregate in bundle.aggregates {
            let writeUCs = bundle.useCases.filter {
                $0.aggregateSpecId == aggregate.aggregateSpecId && !ApiRenderer.isReadUseCase($0.useCase)
            }
            let presentersForAggregate = bundle.presenters.filter { $0.aggregateRef == aggregate.name }
            guard !writeUCs.isEmpty || !presentersForAggregate.isEmpty else { continue }  // skip aggregates with neither write UC nor presenter

            // ApiHandler.swift — Phase 1.i write methods + Phase 1.k read methods
            let presentersForAgg = bundle.presenters.filter { $0.aggregateRef == aggregate.name }
            let handlerPath = "Sources/\(aggregate.name)Aggregate/Adapter/ApiHandler.swift"
            if !existingPaths.contains(handlerPath) {
                let content = try renderApiHandler(
                    aggregate: aggregate,
                    writeUCs: writeUCs,
                    presenters: presentersForAgg,
                    sharedImport: sharedImport
                )
                outputs.append((handlerPath, content, "apiHandler"))
            }

            // ApiComponents+<A>ApiError.swift
            let componentsPath = "Sources/\(aggregate.name)Aggregate/Adapter/ApiComponents/ApiComponents+\(aggregate.name)ApiError.swift"
            if !existingPaths.contains(componentsPath) {
                let content = try renderApiComponentsError(
                    aggregate: aggregate,
                    sharedImport: sharedImport
                )
                outputs.append((componentsPath, content, "apiComponentsError"))
            }
        }
        return outputs
    }

    private static func renderApiHandler(
        aggregate: AggregateSpec,
        writeUCs: [UseCaseSpec],
        presenters: [PresenterSpec],
        sharedImport: String
    ) throws -> String {
        let methodTemplate = try TemplateLoader.loadTemplate(name: "Api/ApiHandlerMethod.swift", ext: "template")
        let readMethodTemplate = try TemplateLoader.loadTemplate(name: "Api/ApiHandlerReadMethod.swift", ext: "template")
        let aggIdName = aggregate.identityName

        var methods: [String] = []
        // Write UC methods (Phase 1.i)
        for uc in writeUCs {
            let ucPascal = CaseTransformer.upperCamel(uc.useCase)
            let methodContent = TemplateRenderer.render(template: methodTemplate, vars: [
                "ucCamel": uc.useCase,
                "UC": ucPascal,
                "aggIdName": aggIdName,
            ]).output
            methods.append(methodContent)
        }
        // Read presenter methods (Phase 1.k)
        for presenter in presenters {
            // Assume single path param = first input field (v1)
            let pathParamName = presenter.input.fields.first?.name ?? aggIdName
            let ucCamel = CaseTransformer.lowerCamel(presenter.name)
            let methodContent = TemplateRenderer.render(template: readMethodTemplate, vars: [
                "ucCamel": ucCamel,
                "Name": presenter.name,
                "pathParamName": pathParamName,
            ]).output
            methods.append(methodContent)
        }

        let handlerTemplate = try TemplateLoader.loadTemplate(name: "Api/ApiHandler.swift", ext: "template")
        return TemplateRenderer.render(template: handlerTemplate, vars: [
            "SharedImport": sharedImport,
            "A": aggregate.name,
            "UC_HANDLER_METHODS": methods.joined(separator: "\n"),
        ]).output
    }

    private static func renderApiComponentsError(
        aggregate: AggregateSpec,
        sharedImport: String
    ) throws -> String {
        let template = try TemplateLoader.loadTemplate(name: "Api/ApiComponentsError.swift", ext: "template")

        // Build exhaustive switch cases from bundle.aggregates[].invariants[].errorCode (dedup)
        let errorCodes: [String] = aggregate.invariants
            .map(\.errorCode)
            .reduce(into: [String]()) { acc, code in
                if !acc.contains(code) { acc.append(code) }
            }
        let switchCases: String
        if errorCodes.isEmpty {
            // No invariants → <A>Error has only placeholder/synthetic cases.
            // Emit default fallback so switch is exhaustive without false 1:1 mapping.
            switchCases = "        default: return nil"
        } else {
            switchCases = errorCodes
                .map { "        case .\($0): self = .\($0)" }
                .joined(separator: "\n")
        }

        return TemplateRenderer.render(template: template, vars: [
            "SharedImport": sharedImport,
            "A": aggregate.name,
            "ERROR_CASES_EXHAUSTIVE": switchCases,
        ]).output
    }
}
