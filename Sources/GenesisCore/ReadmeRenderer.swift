import Foundation

public enum ReadmeRenderer {
    public static func renderReadme(
        bundle: FullBundle,
        contextName: String,
        genesisVersion: String
    ) throws -> (path: String, content: String) {
        var aggregateLines: [String] = []
        for aggregate in bundle.aggregates {
            let ucCount = bundle.useCases.filter { $0.aggregateSpecId == aggregate.aggregateSpecId }.count
            aggregateLines.append("- **\(aggregate.name)** — \(ucCount) use case\(ucCount == 1 ? "" : "s")")
        }
        let template = try TemplateLoader.loadTemplate(name: "README.md", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "ContextName": contextName,
                "GenesisVersion": genesisVersion,
                "BundleId": bundle.bundleId,
                "AggregateList": aggregateLines.joined(separator: "\n"),
                "AggregateCount": String(bundle.aggregates.count),
                "UseCaseCount": String(bundle.useCases.count),
                "DtoCount": String(bundle.dtos.count),
            ]
        )
        return ("README.md", rendered.output)
    }

    public static func renderClaudeMd(
        bundle: FullBundle,
        contextName: String,
        genesisVersion: String
    ) throws -> (path: String, content: String) {
        let template = try TemplateLoader.loadTemplate(name: "CLAUDE.md", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "ContextName": contextName,
                "GenesisVersion": genesisVersion,
                "BundleId": bundle.bundleId,
            ]
        )
        return ("CLAUDE.md", rendered.output)
    }
}
