import Foundation

public enum PackageRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        genesisVersion: String,
        adapter: Adapter
    ) throws -> (path: String, content: String) {
        // Phase 1.f: infra is universal — Shared target ALWAYS needed.
        // (Phase 1.e: needsShared = !bundle.dtos.isEmpty || !adapter.customTypes.isEmpty;
        //  Phase 1.f drops the conditional — every project gets ContextShared infra files.)
        let needsShared = true

        let productTemplate = try TemplateLoader.loadTemplate(name: "PackageProduct.swift", ext: "template")
        let targetTemplate = try TemplateLoader.loadTemplate(name: "PackageTarget.swift", ext: "template")

        let sharedDependencyLine: String = needsShared
            ? "                .target(name: \"\(contextName)Shared\"),\n"
            : ""

        // Phase 1.i: OpenAPI plugin conditional — only emit when aggregate has at least 1 write UC.
        func hasWriteUC(_ agg: AggregateSpec) -> Bool {
            bundle.useCases.contains { uc in
                uc.aggregateSpecId == agg.aggregateSpecId && !ApiRenderer.isReadUseCase(uc.useCase)
            }
        }
        let anyAggregateHasWriteUC = bundle.aggregates.contains(where: hasWriteUC)

        var productLines: [String] = []
        var targetLines: [String] = []
        for aggregate in bundle.aggregates {
            let p = TemplateRenderer.render(template: productTemplate, vars: ["Aggregate": aggregate.name])
            productLines.append(p.output.trimmingCharacters(in: CharacterSet.newlines))

            // Phase 1.i: conditional OpenAPI dep + resources + plugin per aggregate
            let aggHasWrite = hasWriteUC(aggregate)
            let openApiTargetDep: String = aggHasWrite
                ? "                .product(name: \"OpenAPIRuntime\", package: \"swift-openapi-runtime\"),\n"
                : ""
            let openApiResources: String = aggHasWrite
                ? "            resources: [\n                .process(\"openapi.yaml\"),\n                .process(\"openapi-generator-config.yaml\"),\n            ],\n"
                : ""
            let openApiPlugin: String = aggHasWrite
                ? "                .plugin(name: \"OpenAPIGenerator\", package: \"swift-openapi-generator\"),\n"
                : ""

            let t = TemplateRenderer.render(
                template: targetTemplate,
                vars: [
                    "Aggregate": aggregate.name,
                    "SharedDependencyLine": sharedDependencyLine,
                    "OpenApiTargetDep": openApiTargetDep,
                    "OpenApiResources": openApiResources,
                    "OpenApiPlugin": openApiPlugin,
                ]
            )
            targetLines.append(t.output.trimmingCharacters(in: CharacterSet.newlines))
        }

        var sharedProductLines: [String] = []
        var sharedTargetLines: [String] = []
        if needsShared {
            let sharedProductTemplate = try TemplateLoader.loadTemplate(name: "PackageSharedProduct.swift", ext: "template")
            let sharedTargetTemplate = try TemplateLoader.loadTemplate(name: "PackageSharedTarget.swift", ext: "template")
            let sp = TemplateRenderer.render(sharedProductTemplate, contextName: contextName)
            let st = TemplateRenderer.render(sharedTargetTemplate, contextName: contextName)
            sharedProductLines.append(sp.output.trimmingCharacters(in: CharacterSet.newlines))
            sharedTargetLines.append(st.output.trimmingCharacters(in: CharacterSet.newlines))
        }

        let testTargetTemplate = try TemplateLoader.loadTemplate(name: "PackageTestTarget.swift", ext: "template")
        let testDeps = bundle.aggregates.map { "\"\($0.name)Aggregate\"" }.joined(separator: ", ")
        let testBlock = TemplateRenderer.render(
            template: testTargetTemplate,
            vars: [
                "ContextName": contextName,
                "TestDependencies": testDeps,
            ]
        )

        // Phase 1.g.2: conditional context target — only when bundle has context-level readmodels.
        // Deps use UNIQUE sourceAggregate set sorted alphabetically (per audit M1+M2).
        var contextProductLine: String = ""
        var contextTargetBlock: String = ""
        if ContextProjectionModelRenderer.hasContextLevel(bundle: bundle) {
            let uniqueSources = ContextProjectionModelRenderer.uniqueSourceAggregates(bundle: bundle)
            let aggregateDepLines = uniqueSources
                .map { "                    .target(name: \"\($0)Aggregate\")," }
                .joined(separator: "\n")
            let contextTargetTemplate = try TemplateLoader.loadTemplate(name: "PackageContextTarget.swift", ext: "template")
            let ctxBlock = TemplateRenderer.render(template: contextTargetTemplate, vars: [
                "ContextName": contextName,
                "AggregateDepLines": aggregateDepLines,
            ])
            contextTargetBlock = "\n" + ctxBlock.output.trimmingCharacters(in: CharacterSet.newlines)
            contextProductLine = "\n        .library(name: \"\(contextName)\", targets: [\"\(contextName)\"]),"
        }

        let openApiDependencies: String = anyAggregateHasWriteUC
            ? "        .package(url: \"https://github.com/apple/swift-openapi-generator\", from: \"1.0.0\"),\n        .package(url: \"https://github.com/apple/swift-openapi-runtime\", from: \"1.0.0\"),"
            : ""

        let mainTemplate = try TemplateLoader.loadTemplate(name: "Package.swift", ext: "template")
        let rendered = TemplateRenderer.render(
            template: mainTemplate,
            vars: [
                "ContextName": contextName,
                "GenesisVersion": genesisVersion,
                "ProductsList": productLines.joined(separator: "\n") + contextProductLine,
                "TargetsList": targetLines.joined(separator: "\n") + contextTargetBlock,
                "SharedProductsList": sharedProductLines.joined(separator: "\n"),
                "SharedTargetsList": sharedTargetLines.joined(separator: "\n"),
                "TestTargetBlock": testBlock.output.trimmingCharacters(in: CharacterSet.newlines),
                "OpenApiDependencies": openApiDependencies,
            ]
        )
        return ("Package.swift", rendered.output)
    }
}

extension TemplateRenderer {
    /// Convenience: render with a single ContextName variable.
    static func render(_ template: String, contextName: String) -> RenderResult {
        render(template: template, vars: ["ContextName": contextName])
    }
}
