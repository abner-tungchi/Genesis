import Foundation

/// Phase 1.g.2: Cross-aggregate ReadModel codegen support — emits the 3 context-level
/// yaml resources needed for the `{Context}` SwiftPM target with `ModelGeneratorPlugin`:
///
///   - `Sources/{Context}/event.yaml` (= `{}` — context target emits no events of its own)
///   - `Sources/{Context}/projection-model.yaml` (cross-aggregate readmodel entries)
///   - `Sources/{Context}/event-generator-config.yaml` (dependencies list)
///
/// Returns empty `[]` when bundle has no context-level readmodels — no orphan files emitted.
public enum ContextProjectionModelRenderer {

    public static func render(
        bundle: FullBundle,
        contextName: String
    ) throws -> [(path: String, content: String, role: String)] {
        let contextLevel = bundle.readModels.filter { $0.aggregateRef == "<context-level>" }
        guard !contextLevel.isEmpty else { return [] }

        var outputs: [(String, String, String)] = []

        // 1. event.yaml = {}
        let eventTpl = try TemplateLoader.loadTemplate(name: "Context/event.yaml", ext: "template")
        outputs.append((
            "Sources/\(contextName)/event.yaml",
            eventTpl,
            "contextEventYaml"
        ))

        // 2. projection-model.yaml — context-level entries only
        let entryTpl = try TemplateLoader.loadTemplate(name: "projection-model.yaml.entry", ext: "template")
        let entries: [String] = contextLevel.map { entry in
            let normalizedEvents = entry.eventRefs
                .map { CaseTransformer.upperCamel($0.name) }
            let eventList = normalizedEvents
                .map { "    - \($0)" }
                .joined(separator: "\n")
            let rendered = TemplateRenderer.render(template: entryTpl, vars: [
                "ReadModelName": entry.name,
                "EventList": eventList,
            ])
            return rendered.output
        }
        let mainTpl = try TemplateLoader.loadTemplate(name: "projection-model.yaml", ext: "template")
        let pmRendered = TemplateRenderer.render(template: mainTpl, vars: [
            "ProjectionModelEntries": entries.joined(separator: "\n")
        ])
        outputs.append((
            "Sources/\(contextName)/projection-model.yaml",
            pmRendered.output,
            "contextProjectionModel"
        ))

        // 3. event-generator-config.yaml
        // Per audit M1+M2: deps = UNIQUE sourceAggregate set across all context-level
        // readmodels, sorted alphabetically for determinism (match OC pattern).
        let uniqueSourceAggregates: [String] = Array(
            Set(contextLevel.flatMap { $0.eventRefs.map(\.sourceAggregate) })
        ).sorted()
        let depsList = uniqueSourceAggregates
            .map { "  - \($0)Aggregate" }
            .joined(separator: "\n")
        let cfgTpl = try TemplateLoader.loadTemplate(name: "Context/event-generator-config.yaml", ext: "template")
        let cfgRendered = TemplateRenderer.render(template: cfgTpl, vars: [
            "AggregateDepsList": depsList,
            "ContextName": contextName,
        ])
        outputs.append((
            "Sources/\(contextName)/event-generator-config.yaml",
            cfgRendered.output,
            "contextGeneratorConfig"
        ))

        return outputs
    }

    /// Phase 1.g.2 helper: returns the unique sorted source aggregate set for any
    /// context-level readmodel (used by PackageRenderer for context target dependencies).
    public static func uniqueSourceAggregates(bundle: FullBundle) -> [String] {
        let contextLevel = bundle.readModels.filter { $0.aggregateRef == "<context-level>" }
        return Array(
            Set(contextLevel.flatMap { $0.eventRefs.map(\.sourceAggregate) })
        ).sorted()
    }

    public static func hasContextLevel(bundle: FullBundle) -> Bool {
        bundle.readModels.contains { $0.aggregateRef == "<context-level>" }
    }
}
