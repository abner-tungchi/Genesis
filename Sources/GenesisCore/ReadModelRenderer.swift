import Foundation

/// Phase 1.g + 1.g.2: ReadModel codegen renderer.
///
/// Consumes `bundle.readModels[]` entries (written by /readmodel skill) and emits
/// 3 OC-canonical files per entry:
///   1. {Noun}ReadModel.swift
///   2. Get{Noun}Presenter.swift  (empty when() body + TODO; scaffold-once)
///   3. {ProjectionStreamPrefix}Get{Noun}Projection.js
///
/// Per-aggregate (aggregateRef = aggregate name):
///   - Swift files in `Sources/{Aggregate}Aggregate/Usecase/Projector/Get{Noun}/`
/// Cross-aggregate (aggregateRef = "<context-level>") (Phase 1.g.2):
///   - Swift files in `Sources/{Context}/Projector/Get{Noun}/`
///   - Presenter has `import {Agg}Aggregate` for each unique source aggregate
///
/// projection-model.yaml entries:
///   - Per-aggregate → produced by `ProjectionModelRenderer` (existing)
///   - Cross-aggregate → produced by `ContextProjectionModelRenderer` (Phase 1.g.2)
public enum ReadModelRenderer {

    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        existingPresenterPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)] {
        var outputs: [(String, String, String)] = []
        let prefix = try streamPrefix(contextName: contextName)
        let sharedImport = "import \(contextName)Shared"

        for entry in bundle.readModels {
            let aggRef = entry.aggregateRef ?? "<context-level>"
            // Phase 1.g.2: cross-aggregate now supported. Per-aggregate still validates the ref.
            if aggRef != "<context-level>" {
                guard bundle.aggregates.contains(where: { $0.name == aggRef }) else {
                    throw GenesisError.bundleInvalid(
                        reason: "readModel '\(entry.name)' aggregateRef '\(aggRef)' not found in bundle.aggregates[]"
                    )
                }
            }
            // Schema validation (audit Phase 1.g H3)
            guard let key = entry.key else {
                throw GenesisError.bundleInvalid(
                    reason: "readModel '\(entry.name)' missing 'key'; run /readmodel skill to update"
                )
            }
            guard !entry.eventRefs.isEmpty else {
                throw GenesisError.bundleInvalid(
                    reason: "readModel '\(entry.name)' missing 'events[].sourceAggregate'; run /readmodel skill to update (legacy minimal shape unsupported)"
                )
            }
            guard entry.name.hasPrefix("Get") else {
                throw GenesisError.bundleInvalid(
                    reason: "readModel '\(entry.name)' must start with 'Get'"
                )
            }
            // Cross-aggregate: validate every event's sourceAggregate exists in bundle
            for ref in entry.eventRefs {
                guard bundle.aggregates.contains(where: { $0.name == ref.sourceAggregate }) else {
                    throw GenesisError.bundleInvalid(
                        reason: "readModel '\(entry.name)' event '\(ref.name)' sourceAggregate '\(ref.sourceAggregate)' not found in bundle.aggregates[]"
                    )
                }
            }

            let noun = String(entry.name.dropFirst("Get".count))
            let readModelTypeName = "\(noun)ReadModel"
            let presenterTypeName = "\(entry.name)Presenter"

            // Phase 1.g.2 dispatch: per-aggregate vs context-level
            let projectorDir: String
            let aggregateImports: String
            if aggRef == "<context-level>" {
                projectorDir = "Sources/\(contextName)/Projector/\(entry.name)"
                let uniqueSources = Array(Set(entry.eventRefs.map(\.sourceAggregate))).sorted()
                aggregateImports = uniqueSources
                    .map { "import \($0)Aggregate" }
                    .joined(separator: "\n")
            } else {
                projectorDir = "Sources/\(aggRef)Aggregate/Usecase/Projector/\(entry.name)"
                aggregateImports = ""  // per-aggregate: same-module event types
            }

            // Normalize event names (Phase 1.g audit H2)
            let normalizedEvents: [(typeName: String, sourceAggregate: String)] = entry.eventRefs.map {
                (CaseTransformer.upperCamel($0.name), $0.sourceAggregate)
            }

            // 1. ReadModel.swift
            let rmPath = "\(projectorDir)/\(readModelTypeName).swift"
            let rmTemplate = try TemplateLoader.loadTemplate(name: "Projector/ReadModel.swift", ext: "template")
            let storedFieldDecls = try renderStoredFieldDeclarations(entry.storedFields)
            let storedFieldDefaults = try renderStoredFieldDefaults(entry.storedFields)
            let rmContent = TemplateRenderer.render(template: rmTemplate, vars: [
                "SharedImport": sharedImport,
                "ReadModelTypeName": readModelTypeName,
                "KeyType": key.type,
                "KeyField": key.field,
                "StoredFieldDeclarations": storedFieldDecls,
                "StoredFieldDefaults": storedFieldDefaults,
            ]).output
            outputs.append((rmPath, rmContent, "readmodel"))

            // 2. Presenter.swift — scaffold-once (Phase 1.g audit H6)
            let prPath = "\(projectorDir)/\(presenterTypeName).swift"
            if !existingPresenterPaths.contains(prPath) {
                let prTemplate = try TemplateLoader.loadTemplate(name: "Projector/Presenter.swift", ext: "template")
                let whenMethods = renderWhenMethods(eventTypeNames: normalizedEvents.map(\.typeName))
                let prContent = TemplateRenderer.render(template: prTemplate, vars: [
                    "SharedImport": sharedImport,
                    "AggregateImports": aggregateImports,  // empty for per-agg, multi-line for context-level (audit M3)
                    "Name": entry.name,
                    "KeyType": key.type,
                    "KeyField": key.field,
                    "PresenterTypeName": presenterTypeName,
                    "ReadModelTypeName": readModelTypeName,
                    "ProjectionStreamPrefix": prefix.projection,
                    "WhenMethods": whenMethods,
                ]).output
                outputs.append((prPath, prContent, "presenter"))
            }

            // 3. JS projection
            let jsPath = "projections/\(prefix.projection)\(entry.name)Projection.js"
            let jsTemplate = try TemplateLoader.loadTemplate(name: "Projector/Projection.js", ext: "template")
            let uniqueSources = Array(Set(normalizedEvents.map(\.sourceAggregate))).sorted()
            let sourceStreamList = uniqueSources
                .map { "\"$ce-\(prefix.sourceCategory)\($0)\"" }
                .joined(separator: ", ")
            let handlerLines = normalizedEvents
                .map { "    \($0.typeName): handleEvent," }
                .joined(separator: "\n")
            let jsContent = TemplateRenderer.render(template: jsTemplate, vars: [
                "SourceStreamList": sourceStreamList,
                "HandlerLines": handlerLines,
                "ProjectionStreamPrefix": prefix.projection,
                "Name": entry.name,
                "FromEventPayload": key.fromEventPayload,
            ]).output
            outputs.append((jsPath, jsContent, "projection"))
        }
        return outputs
    }

    // MARK: - Stream prefix derivation

    public static func streamPrefix(contextName: String) throws -> (projection: String, sourceCategory: String) {
        let stripped: String = {
            if contextName.hasSuffix("Context") {
                return String(contextName.dropLast("Context".count))
            }
            return contextName
        }()
        if stripped.isEmpty {
            throw GenesisError.bundleInvalid(
                reason: "contextName must not equal 'Context' alone; cannot derive stream prefix"
            )
        }
        let aliases: [String: String] = ["Opportunity": "OC"]
        let core: String = aliases[stripped] ?? CaseTransformer.upperSnake(stripped)
        return (projection: "\(core)_", sourceCategory: core)
    }

    // MARK: - Stored fields default heuristic

    private static func renderStoredFieldDeclarations(_ fields: [ReadModelStoredField]) throws -> String {
        guard !fields.isEmpty else { return "" }
        return fields
            .map { "    package var \($0.name): \($0.type)" }
            .joined(separator: "\n")
    }

    private static func renderStoredFieldDefaults(_ fields: [ReadModelStoredField]) throws -> String {
        guard !fields.isEmpty else { return "" }
        var lines: [String] = []
        for f in fields {
            let defaultExpr = try defaultExpression(for: f)
            lines.append("        self.\(f.name) = \(defaultExpr)")
        }
        return lines.joined(separator: "\n")
    }

    private static func defaultExpression(for field: ReadModelStoredField) throws -> String {
        if let explicit = field.defaultValue { return explicit }
        let type = field.type
        if type.hasSuffix("?") { return "nil" }
        if type.hasPrefix("Optional<") && type.hasSuffix(">") { return "nil" }
        if type.hasPrefix("Set<") && type.hasSuffix(">") { return "Set()" }
        if type.hasPrefix("Array<") && type.hasSuffix(">") { return "[]" }
        if type.hasPrefix("Dictionary<") && type.hasSuffix(">") { return "[:]" }
        if type.hasPrefix("[") && type.hasSuffix("]") {
            let inner = String(type.dropFirst().dropLast())
            var depth = 0
            var hasTopColon = false
            for c in inner {
                if c == "<" || c == "[" || c == "(" { depth += 1 }
                else if c == ">" || c == "]" || c == ")" { depth -= 1 }
                else if c == ":" && depth == 0 { hasTopColon = true; break }
            }
            return hasTopColon ? "[:]" : "[]"
        }
        throw GenesisError.bundleInvalid(
            reason: "readModel storedField '\(field.name)' type '\(type)' has no inferrable default; add `default` in bundle entry"
        )
    }

    private static func renderWhenMethods(eventTypeNames: [String]) -> String {
        eventTypeNames.map { name in
            """

                package func when(readModel: inout ReadModelType, event: \(name)) throws {
                    // TODO(Phase 1.g): mutation logic not yet codegen'd. Hand-fill below, or wait
                    // for /readmodel-mutation v2 skill. Plugin requires this method to satisfy the
                    // generated projector protocol; current body intentionally no-op.
                    _ = readModel
                    _ = event
                }
            """
        }.joined(separator: "\n")
    }
}
