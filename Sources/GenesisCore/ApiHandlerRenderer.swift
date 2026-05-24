import Foundation

/// Phase 1.i: ApiHandler.swift + ApiComponents+<A>ApiError.swift emission per aggregate.
/// Phase 1.k.2: + context-level emission when bundle has cross-agg presenter (audit M3 via PresenterPlacementResolver).
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

        // Per-aggregate handler + components
        for aggregate in bundle.aggregates {
            let writeUCs = bundle.useCases.filter {
                $0.aggregateSpecId == aggregate.aggregateSpecId && !ApiRenderer.isReadUseCase($0.useCase)
            }
            let presentersForAgg = bundle.presenters.filter { $0.aggregateRef == aggregate.name }
            guard !writeUCs.isEmpty || !presentersForAgg.isEmpty else { continue }

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

            let componentsPath = "Sources/\(aggregate.name)Aggregate/Adapter/ApiComponents/ApiComponents+\(aggregate.name)ApiError.swift"
            if !existingPaths.contains(componentsPath) {
                let content = try renderApiComponentsError(
                    aggregate: aggregate,
                    sharedImport: sharedImport
                )
                outputs.append((componentsPath, content, "apiComponentsError"))
            }
        }

        // Phase 1.k.2: Context-level handler + components (only if bundle has cross-agg presenter).
        if PresenterPlacementResolver.hasContextLevelPresenter(bundle: bundle) {
            let contextPresenters = bundle.presenters.filter { $0.aggregateRef == "<context-level>" }
            let sourceAggs = PresenterPlacementResolver.contextSourceAggregates(bundle: bundle)
            let sourceAggSpecs = bundle.aggregates.filter { sourceAggs.contains($0.name) }

            let contextHandlerPath = "Sources/\(contextName)/Adapter/ApiHandler.swift"
            if !existingPaths.contains(contextHandlerPath) {
                let content = try renderContextApiHandler(
                    contextName: contextName,
                    presenters: contextPresenters,
                    sourceAggregates: sourceAggSpecs,
                    sharedImport: sharedImport
                )
                outputs.append((contextHandlerPath, content, "contextApiHandler"))
            }

            let contextComponentsPath = "Sources/\(contextName)/Adapter/ApiComponents/ApiComponents+\(contextName)ApiError.swift"
            if !existingPaths.contains(contextComponentsPath) {
                let content = try renderContextApiComponentsError(
                    contextName: contextName,
                    sourceAggregates: sourceAggSpecs,
                    sharedImport: sharedImport
                )
                outputs.append((contextComponentsPath, content, "contextApiComponentsError"))
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
        let queryErrorType = "\(aggregate.name)QueryError"

        var methods: [String] = []
        for uc in writeUCs {
            let ucPascal = CaseTransformer.upperCamel(uc.useCase)
            let methodContent = TemplateRenderer.render(template: methodTemplate, vars: [
                "ucCamel": uc.useCase,
                "UC": ucPascal,
                "aggIdName": aggIdName,
            ]).output
            methods.append(methodContent)
        }
        for presenter in presenters {
            let pathParamName = presenter.input.fields.first?.name ?? aggIdName
            let ucCamel = CaseTransformer.lowerCamel(presenter.name)
            let methodContent = TemplateRenderer.render(template: readMethodTemplate, vars: [
                "ucCamel": ucCamel,
                "Name": presenter.name,
                "pathParamName": pathParamName,
                "QueryErrorType": queryErrorType,
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

        let errorCodes: [String] = aggregate.invariants
            .map(\.errorCode)
            .reduce(into: [String]()) { acc, code in
                if !acc.contains(code) { acc.append(code) }
            }
        let switchCases: String
        if errorCodes.isEmpty {
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

    // MARK: - Phase 1.k.2 context-level emission

    private static func renderContextApiHandler(
        contextName: String,
        presenters: [PresenterSpec],
        sourceAggregates: [AggregateSpec],
        sharedImport: String
    ) throws -> String {
        let readMethodTemplate = try TemplateLoader.loadTemplate(name: "Api/ApiHandlerReadMethod.swift", ext: "template")
        let template = try TemplateLoader.loadTemplate(name: "Api/ApiHandlerContext.swift", ext: "template")
        let queryErrorType = "\(contextName)QueryError"

        let aggregateImports = sourceAggregates
            .map { "import \($0.name)Aggregate" }
            .sorted()
            .joined(separator: "\n")

        // mapToApiError multi-branch: source aggregates first (domain errors), then QueryError last (read-side).
        var branches: [String] = []
        for agg in sourceAggregates.sorted(by: { $0.name < $1.name }) {
            branches.append("""
                if let contextError = error as? ContextError<\(agg.name)Error> {
                    return .init(from: contextError)
                }
            """)
        }
        branches.append("""
            if let contextError = error as? ContextError<\(queryErrorType)> {
                return .init(from: contextError)
            }
        """)
        let mapBranches = branches.joined(separator: "\n")

        var methods: [String] = []
        for presenter in presenters {
            // v1 assumption: 1 input field (BundleParser D-validation enforced earlier? No — D1 only checks aggregateRef; multi-field check is /presenter-fill exit 3).
            let pathParamName = presenter.input.fields.first?.name ?? "id"
            let ucCamel = CaseTransformer.lowerCamel(presenter.name)
            let methodContent = TemplateRenderer.render(template: readMethodTemplate, vars: [
                "ucCamel": ucCamel,
                "Name": presenter.name,
                "pathParamName": pathParamName,
                "QueryErrorType": queryErrorType,
            ]).output
            methods.append(methodContent)
        }

        return TemplateRenderer.render(template: template, vars: [
            "AggregateImports": aggregateImports,
            "SharedImport": sharedImport,
            "Context": contextName,
            "MAP_TO_API_ERROR_BRANCHES": mapBranches,
            "UC_HANDLER_METHODS": methods.joined(separator: "\n"),
        ]).output
    }

    private static func renderContextApiComponentsError(
        contextName: String,
        sourceAggregates: [AggregateSpec],
        sharedImport: String
    ) throws -> String {
        let template = try TemplateLoader.loadTemplate(name: "Api/ApiComponentsContextError.swift", ext: "template")

        let aggregateImports = sourceAggregates
            .map { "import \($0.name)Aggregate" }
            .sorted()
            .joined(separator: "\n")

        // Per-aggregate overloads: init(from: ContextError<{A}Error>) + init?(from: {A}Error)
        var overloads: [String] = []
        for agg in sourceAggregates.sorted(by: { $0.name < $1.name }) {
            let errorCodes: [String] = agg.invariants
                .map(\.errorCode)
                .reduce(into: [String]()) { acc, code in
                    if !acc.contains(code) { acc.append(code) }
                }
            let switchCases: String
            if errorCodes.isEmpty {
                switchCases = "        default: return nil"
            } else {
                switchCases = errorCodes
                    .map { "        case .\($0): self = .\($0)" }
                    .joined(separator: "\n")
            }
            overloads.append("""
                package init(from error: ContextError<\(agg.name)Error>) {
                    self = .init(from: error.error) ?? .undefinedDomainError
                }

                package init?(from error: \(agg.name)Error) {
                    switch error {
            \(switchCases)
                    }
                }
            """)
        }
        let overloadsBlock = overloads.joined(separator: "\n\n")

        return TemplateRenderer.render(template: template, vars: [
            "AggregateImports": aggregateImports,
            "SharedImport": sharedImport,
            "Context": contextName,
            "PER_AGGREGATE_OVERLOADS": overloadsBlock,
        ]).output
    }
}
