import Foundation

public enum ProjectionModelRenderer {
    public static func render(
        aggregateName: String,
        aggregateSpecId: String,
        aggregateEventNames: Set<String>,
        createdEventTypeName: String,
        readModels: [ReadModelSpec]
    ) throws -> (path: String, content: String, role: String) {
        // Phase 1.g: 統一 event-name normalization。bundle 內 readmodel 來自 /readmodel skill 用 lower-camel
        // (e.g. `userAccessProfileCreated`)，aggregateEventNames 已是 UpperCamel — 兩者必須 normalize
        // 才比得到，否則所有 entries 被 filter 掉走 fallback path。
        // Scope: per-aggregate readmodels (aggregateRef matches OR legacy aggregateSpecId match).
        // Cross-aggregate entries (aggregateRef == "<context-level>") 不進 per-aggregate yaml (Phase 1.g.2 走 context-level yaml).
        let scopedReadModels: [ReadModelSpec] = readModels
            .filter { rm in
                if let ref = rm.aggregateRef {
                    if ref == "<context-level>" { return false }  // defer Phase 1.g.2
                    return ref == aggregateName
                }
                // Legacy fallback: match by aggregateSpecId
                return rm.aggregateSpecId == nil || rm.aggregateSpecId == aggregateSpecId
            }
            .map { rm in
                // Normalize event names to UpperCamel + filter to aggregate's declared events
                let normalized = rm.eventNames
                    .map { CaseTransformer.upperCamel($0) }
                    .filter { aggregateEventNames.contains($0) }
                return ReadModelSpec(
                    readModelSpecId: rm.readModelSpecId,
                    aggregateSpecId: rm.aggregateSpecId,
                    name: rm.name,
                    eventNames: normalized,
                    aggregateRef: rm.aggregateRef,
                    key: rm.key,
                    storedFields: rm.storedFields,
                    eventRefs: rm.eventRefs,
                    comment: rm.comment
                )
            }
            .filter { !$0.eventNames.isEmpty }

        let entries: [String]
        if scopedReadModels.isEmpty {
            entries = [makeFallbackEntry(aggregateName: aggregateName, createdEventTypeName: createdEventTypeName)]
        } else {
            entries = scopedReadModels.map { makeEntry(name: $0.name, events: $0.eventNames) }
        }

        let mainTemplate = try TemplateLoader.loadTemplate(name: "projection-model.yaml", ext: "template")
        let rendered = TemplateRenderer.render(
            template: mainTemplate,
            vars: ["ProjectionModelEntries": entries.joined(separator: "\n")]
        )
        return (
            "Sources/\(aggregateName)Aggregate/projection-model.yaml",
            rendered.output,
            "projectionModel"
        )
    }

    private static func makeFallbackEntry(aggregateName: String, createdEventTypeName: String) -> String {
        let name = "Get\(aggregateName)Existence"
        return makeEntry(name: name, events: [createdEventTypeName])
    }

    private static func makeEntry(name: String, events: [String]) -> String {
        let eventList = events.map { "    - \($0)" }.joined(separator: "\n")
        let entryTemplate: String
        do {
            entryTemplate = try TemplateLoader.loadTemplate(name: "projection-model.yaml.entry", ext: "template")
        } catch {
            entryTemplate = "{ReadModelName}:\n  model: readModel\n  events:\n{EventList}\n"
        }
        let rendered = TemplateRenderer.render(
            template: entryTemplate,
            vars: [
                "ReadModelName": name,
                "EventList": eventList,
            ]
        )
        return rendered.output
    }
}
