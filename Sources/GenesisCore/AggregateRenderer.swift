import Foundation

public enum AggregateRenderer {
    public static func render(
        spec: AggregateSpec,
        bundle: FullBundle,
        adapter: Adapter,
        contextName: String
    ) throws -> [(path: String, content: String, role: String)] {
        let aggregateName = spec.name
        let aggregateDir = "Sources/\(aggregateName)Aggregate"

        let aggregateUseCases = bundle.useCases.filter { $0.aggregateSpecId == spec.aggregateSpecId }
        let createdUseCase = try AdapterApplier.resolveCreatedUseCase(
            for: spec, useCases: aggregateUseCases, adapter: adapter
        )
        let createdEventTypeName = CaseTransformer.upperCamel(createdUseCase.emittedEvent)
        let deletedEventTypeName = "\(aggregateName)Deleted"

        var outputs: [(String, String, String)] = []

        // Phase 1.e: compute SharedImport once for all aggregate-target Swift files that may reference
        // DTO / customType identifiers (which live in {ContextName}Shared). Empty when no Shared target.
        let needsSharedForImport = !bundle.dtos.isEmpty || !adapter.customTypes.isEmpty
        let sharedImportLine: String = needsSharedForImport ? "import \(contextName)Shared" : ""

        outputs.append(try renderAggregate(
            spec: spec,
            createdUseCase: createdUseCase,
            createdEventTypeName: createdEventTypeName,
            deletedEventTypeName: deletedEventTypeName,
            adapter: adapter,
            bundle: bundle,
            contextName: contextName,
            sharedImport: sharedImportLine,
            dir: aggregateDir
        ))

        outputs.append(try renderError(spec: spec, contextName: contextName, dir: aggregateDir))

        outputs.append(renderGenesisTODO(spec: spec, dir: aggregateDir))

        outputs.append(try renderRepository(aggregateName: aggregateName, dir: aggregateDir))

        outputs.append(try renderEventYaml(
            spec: spec,
            useCases: aggregateUseCases,
            createdUseCase: createdUseCase,
            deletedEventTypeName: deletedEventTypeName,
            adapter: adapter,
            bundle: bundle,
            dir: aggregateDir
        ))

        // Phase 1.e: plugin-generated event Swift code references types from {Ctx}Shared (DTOs / customTypes).
        // event-generator-config.yaml's `dependencies` block tells the plugin to `import {Ctx}Shared`
        // in its generated file. Only emit when Shared target exists.
        outputs.append(try renderEventGeneratorConfig(
            dir: aggregateDir,
            contextName: contextName,
            needsShared: needsSharedForImport
        ))

        outputs.append(try renderDeleteCommand(
            aggregateName: aggregateName,
            sharedImport: sharedImportLine,
            dir: aggregateDir
        ))

        let aggregateEventNames = computeEventTypeNames(
            spec: spec,
            deletedEventTypeName: deletedEventTypeName
        )
        outputs.append(try ProjectionModelRenderer.render(
            aggregateName: aggregateName,
            aggregateSpecId: spec.aggregateSpecId,
            aggregateEventNames: aggregateEventNames,
            createdEventTypeName: createdEventTypeName,
            readModels: bundle.readModels
        ))

        for useCase in aggregateUseCases {
            for ucFile in try UseCaseRenderer.render(
                useCase: useCase,
                bundle: bundle,
                adapter: adapter,
                sharedImport: sharedImportLine
            ) {
                outputs.append(ucFile)
            }
        }

        return outputs
    }

    private static func computeEventTypeNames(
        spec: AggregateSpec,
        deletedEventTypeName: String
    ) -> Set<String> {
        var names: Set<String> = []
        for eventName in spec.eventNames {
            names.insert(CaseTransformer.upperCamel(eventName))
        }
        names.insert(deletedEventTypeName)
        return names
    }

    private static func renderAggregate(
        spec: AggregateSpec,
        createdUseCase: UseCaseSpec,
        createdEventTypeName: String,
        deletedEventTypeName: String,
        adapter: Adapter,
        bundle: FullBundle,
        contextName: String,
        sharedImport: String,
        dir: String
    ) throws -> (String, String, String) {
        let knownCustomTypes = bundle.dtoTypeNames.union(adapter.customTypes.map { $0.name })
        let alias = spec.identityName

        // State field declarations (Optional + populated by `when(event:)` in Commands/).
        var stateDecls: [String] = []
        for field in spec.state {
            let resolved = try SwiftTypeResolver.resolve(
                rawType: field.rawType,
                knownCustomTypes: knownCustomTypes,
                adapter: adapter
            )
            stateDecls.append("    package var \(field.name): \(resolved)?")
        }

        // Created-event payload extraction.
        // Source of truth = createUC.eventPayload (NOT input — they may differ; plugin's generated event
        // struct init signature uses event property names exactly).
        let payloadFields: [(name: String, type: String)] = try createdUseCase.eventPayload
            .filter { $0.name != alias }
            .map { field in
                let resolved = try SwiftTypeResolver.resolve(
                    rawType: field.rawType,
                    knownCustomTypes: knownCustomTypes,
                    adapter: adapter
                )
                return (name: field.name, type: resolved)
            }

        // Genesis enforces 1:1 naming between createdEvent payload and aggregate state (aligned with OC reference). Field rename via adapter is intentionally not supported — bundle authors should align naming, not introduce bridging configuration.
        let stateFieldNames = Set(spec.state.map { $0.name })
        let orphanFields = payloadFields.filter { !stateFieldNames.contains($0.name) }
        if !orphanFields.isEmpty {
            throw GenesisError.bundleInvalid(
                reason: "createdEvent payload field(s) \(orphanFields.map { $0.name }) "
                    + "have no matching state in aggregate '\(spec.name)'.\n"
                    + "Fix: rename the event payload field(s) to match aggregate state names, "
                    + "OR add the missing field(s) to aggregate state in bundle. "
                    + "Genesis enforces 1:1 naming (aligned with OC); field rename via adapter is not supported."
            )
        }

        // Category prefix via the single source of truth (StreamNaming) — uppercase letters of contextName
        // (e.g. IAMContext → IAMC, QuotationContext → QC). The read side (ReadModelRenderer JS fromStreams +
        // Presenter categoryRule) derives from the SAME function, so write/read stream prefixes align.
        let categoryPrefix = try StreamNaming.categoryPrefix(contextName: contextName)

        // Phase 1.t / D4 + Phase 1.u / C-ensureInvariant: carry bundle-declared invariants into
        // ensureInvariant() as a commented obligation. Do NOT emit named check*() stubs (avoids "domain
        // theater"; bundle N invariants ≠ author's M checks).
        // honest-hole (Phase 1.y / TDD): ensureInvariant MUST stay a runnable NO-OP. DDDKit runs it pre+post on
        // EVERY apply, including when test fixtures seed state via real createX usecases — a throw here would
        // detonate fixture seeding (whole-aggregate red at SEED, not at the targeted assertion), and a compile-time
        // #error would block ALL tests from running (kills incremental TDD). So the body is comments-only: the
        // invariant's honest RED comes from the invariant TEST (bad state not rejected → test red), and
        // `genesis verify` structurally requires every declared invariant errorCode to have an enabled test.
        let ensureInvariantBody: String
        if spec.invariants.isEmpty {
            ensureInvariantBody = "        // No invariants declared in bundle for this aggregate."
        } else {
            var lines: [String] = [
                "        // GENESIS-TODO: implement aggregate invariants (DDDKit apply() runs this before & after every event).",
                "        // Keep this body runnable (no throw) until filled — a throw breaks fixture seeding. The RED signal",
                "        // is the invariant test (seeds a violating state, expects rejection); genesis verify requires one exists.",
                "        // Bundle-declared invariants:",
            ]
            for inv in spec.invariants {
                let ruleText = inv.rules
                    .map { $0.when == "always" ? $0.rule : "[\($0.when)] \($0.rule)" }
                    .joined(separator: "; ")
                    .replacingOccurrences(of: "\n", with: " ")
                lines.append("        //   - \(inv.title) (\(inv.errorCode)): \(ruleText)")
            }
            lines.append("        // Throw ContextError<\(spec.name)Error>.<errorCode>(message:) on violation.")
            ensureInvariantBody = lines.joined(separator: "\n")
        }

        // Placeholder strings.
        let initParams = payloadFields.map { ", \($0.name): \($0.type)" }.joined()
        let stateAssignments = payloadFields.map { "        self.\($0.name) = \($0.name)" }.joined(separator: "\n")
        var invocationList = ",\n            \(alias): id"
        for f in payloadFields {
            invocationList += ",\n            \(f.name): \(f.name)"
        }
        let replayList = payloadFields.map { ",\n            \($0.name): createdEvent.\($0.name)" }.joined()

        // Phase 1.t.1 / D3a: input-only convenience init for the create use-case caller (/usecase Create pattern).
        // The use-case Input does NOT carry non-input createdEvent payload fields (derived/external domain data),
        // so deriving them is an honest throw GenesisTODO.notImplemented TODO (Phase 1.y; was fatalError, which
        // crashes the test process). Emit ONLY when derivedFields is non-empty; when input
        // business fields already cover the whole payload, the designated init's signature == input and a
        // convenience init would collide. The designated init + rehydration init are UNCHANGED → event replay
        // is unaffected (this convenience init is never on the replay path; only create callers invoke it).
        let inputBusinessFields: [(name: String, type: String)] = try createdUseCase.input
            .filter { $0.name != alias && $0.name != "operatorId" }
            .map { field in
                let resolved = try SwiftTypeResolver.resolve(
                    rawType: field.rawType, knownCustomTypes: knownCustomTypes, adapter: adapter
                )
                return (name: field.name, type: resolved)
            }
        let inputNames = Set(inputBusinessFields.map { $0.name })
        let derivedFieldNames = payloadFields.map { $0.name }.filter { !inputNames.contains($0) }
        let createInputConvenienceInit: String
        if derivedFieldNames.isEmpty {
            createInputConvenienceInit = ""
        } else {
            let convParams = inputBusinessFields.map { ", \($0.name): \($0.type)" }.joined()
            let derivedList = derivedFieldNames.joined(separator: ", ")
            createInputConvenienceInit = """
                // Create entry point used by the create use-case (/usecase Create pattern). The use-case Input does
                // NOT carry non-input createdEvent payload field(s) [\(derivedList)], so deriving them is domain logic.
                package convenience init(id: String\(convParams)) throws {
                    // GENESIS-TODO: derive non-input createdEvent payload field(s) [\(derivedList)] from input
                    // and/or an external source, then delegate to the full init (try self.init(id: id, ...)).
                    throw GenesisTODO.notImplemented("\(spec.name).init: derive non-input payload field(s) [\(derivedList)]")
                }
            """
        }

        let template = try TemplateLoader.loadTemplate(name: "Aggregate.swift", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "Aggregate": spec.name,
                "SharedImport": sharedImport,
                "CategoryPrefix": categoryPrefix,
                "StateFieldDecls": stateDecls.joined(separator: "\n"),
                "CreatedEventTypeName": createdEventTypeName,
                "CreatedEventAliasName": alias,
                "CreatedEventInitParams": initParams,
                "CreatedEventStateAssignments": stateAssignments,
                "CreatedEventInvocationList": invocationList,
                "CreatedEventReplayList": replayList,
                "EnsureInvariantBody": ensureInvariantBody,
                "CreateInputConvenienceInit": createInputConvenienceInit,
            ]
        )
        return ("\(dir)/Entity/\(spec.name).swift", rendered.output, "aggregate")
    }

    /// Phase 1.y: per-aggregate TDD honest-hole marker. Lives in the aggregate target (next to <A>Error.swift),
    /// NOT in {Context}Shared — the aggregate's `import {Context}Shared` is conditional (only when DTOs/customTypes
    /// exist), so a Shared-hosted marker would be unresolvable for a no-DTO bundle. Unfilled domain logic throws
    /// this so the project COMPILES (tests run + go red) instead of failing to build. Sendable: thrown across the
    /// async usecase boundary. grep `GenesisTODO.notImplemented` to find holes; `genesis verify` fails while any remain.
    private static func renderGenesisTODO(spec: AggregateSpec, dir: String) -> (String, String, String) {
        let content = """
        // Genesis TDD honest-hole marker. Unfilled domain logic (command precondition / when reducer /
        // ensureInvariant via create-init) throws this so the project compiles and the targeted test goes RED
        // instead of the whole module failing to build. grep GenesisTODO.notImplemented to find unfilled holes.
        package enum GenesisTODO: Error, Sendable {
            case notImplemented(String)
        }

        """
        return ("\(dir)/\(spec.name)GenesisTODO.swift", content, "genesisTodo")
    }

    private static func renderError(spec: AggregateSpec, contextName: String, dir: String) throws -> (String, String, String) {
        var seenCodes: Set<String> = []
        var lines: [String] = []
        var factories: [String] = []
        for invariant in spec.invariants {
            if seenCodes.insert(invariant.errorCode).inserted {
                let comment = invariant.title.isEmpty ? "" : "  // \(invariant.title)"
                lines.append("    case \(invariant.errorCode)\(comment)")
                // Phase 1.t / D2: per-errorCode ContextError factory (OC AuditQuotingError parity).
                factories.append("    static func \(invariant.errorCode)(function: String = #function, message: String = \"\") -> Self {")
                factories.append("        .init(error: .\(invariant.errorCode), in: .class(\(spec.name).self, function: function), message: message)")
                factories.append("    }")
            }
        }

        // Phase 1.t / D2: factory extension. Skip entirely for placeholder-only (no invariants) —
        // generating a ContextError<…>.placeholder() conflicts with honest-obligation philosophy.
        let factoryBlock: String
        if lines.isEmpty {
            lines.append("    case placeholder  // GENESIS-STUB: no invariants declared in bundle")
            factoryBlock = ""
        } else {
            factoryBlock = "\nextension ContextError where ErrorType == \(spec.name)Error {\n"
                + factories.joined(separator: "\n") + "\n}\n"
        }

        // Phase 1.t / N2: ContextError lives in {Ctx}Shared — error file imports it UNCONDITIONALLY
        // (the Shared target always exists; do NOT gate on needsSharedForImport, which only tracks
        // whether the aggregate references DTO/customType identifiers).
        let template = try TemplateLoader.loadTemplate(name: "AggregateError.swift", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "Aggregate": spec.name,
                "SharedImport": "import \(contextName)Shared",
                "ErrorCases": lines.joined(separator: "\n"),
                "ContextErrorFactories": factoryBlock,
            ]
        )
        return ("\(dir)/\(spec.name)Error.swift", rendered.output, "aggregateError")
    }

    private static func renderRepository(aggregateName: String, dir: String) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "Repository.swift", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: ["Aggregate": aggregateName])
        return ("\(dir)/Usecase/Port/Out/\(aggregateName)Repository.swift", rendered.output, "repository")
    }

    private static func renderDeleteCommand(
        aggregateName: String,
        sharedImport: String,
        dir: String
    ) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "DeleteCommandExtension.swift", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "Aggregate": aggregateName,
                "SharedImport": sharedImport,
            ]
        )
        return ("\(dir)/Entity/Commands/\(aggregateName)+Delete.swift", rendered.output, "commandExtension")
    }

    private static func renderEventYaml(
        spec: AggregateSpec,
        useCases: [UseCaseSpec],
        createdUseCase: UseCaseSpec,
        deletedEventTypeName: String,
        adapter: Adapter,
        bundle: FullBundle,
        dir: String
    ) throws -> (String, String, String) {
        let knownCustomTypes = bundle.dtoTypeNames.union(adapter.customTypes.map { $0.name })
        let eventBlockTemplate = try TemplateLoader.loadTemplate(name: "event.yaml.event", ext: "template")
        let alias = spec.identityName

        var blocks: [String] = []
        var seenEventNames: Set<String> = []

        for eventName in spec.eventNames {
            let eventTypeName = CaseTransformer.upperCamel(eventName)
            if !seenEventNames.insert(eventTypeName).inserted { continue }

            let kind: String = (eventName == createdUseCase.emittedEvent) ? "createdEvent" : "domainEvent"
            let owningUC = useCases.first { $0.emittedEvent == eventName }
            let payload = owningUC?.eventPayload ?? []

            blocks.append(try renderEventBlock(
                template: eventBlockTemplate,
                eventTypeName: eventTypeName,
                kind: kind,
                alias: alias,
                payload: payload,
                adapter: adapter,
                knownCustomTypes: knownCustomTypes
            ))
        }

        if !seenEventNames.contains(deletedEventTypeName) {
            // Phase 1.e: deletedEvent yaml omits aggregateRootId and properties (matches OC ground truth
            // `AuditQuotingDeleted:\n  kind: deletedEvent`; bypass standard event block template).
            blocks.append("\(deletedEventTypeName):\n  kind: deletedEvent\n")
        }

        let mainTemplate = try TemplateLoader.loadTemplate(name: "event.yaml", ext: "template")
        let rendered = TemplateRenderer.render(
            template: mainTemplate,
            vars: ["EventBlocks": blocks.joined(separator: "\n")]
        )
        return ("\(dir)/event.yaml", rendered.output, "eventYaml")
    }

    private static func renderEventBlock(
        template: String,
        eventTypeName: String,
        kind: String,
        alias: String,
        payload: [FieldSpec],
        adapter: Adapter,
        knownCustomTypes: Set<String>
    ) throws -> String {
        var propLines: [String] = []
        for field in payload {
            let resolved = try SwiftTypeResolver.resolve(
                rawType: field.rawType,
                knownCustomTypes: knownCustomTypes,
                adapter: adapter
            )
            // Phase 1.o D5: DDD-kit upstream sample map shape; all type values quoted (D5 lock = B).
            propLines.append("    \(field.name): \"\(resolved)\"")
        }
        if propLines.isEmpty {
            // Phase 1.o D5 fallback: payload empty → single aggregate alias entry, map shape.
            propLines.append("    \(alias): \"String\"")
        }

        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "EventName": eventTypeName,
                "EventKind": kind,
                "AggregateRootIdAlias": alias,
                "PropertiesList": propLines.joined(separator: "\n"),
            ]
        )
        return rendered.output
    }

    private static func renderEventGeneratorConfig(
        dir: String,
        contextName: String,
        needsShared: Bool
    ) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "event-generator-config.yaml", ext: "template")
        // Inject dependencies block (or empty string) — plugin uses this to add `import X` to generated files.
        let dependencies: String = needsShared
            ? "dependencies:\n  - \(contextName)Shared"
            : ""
        let rendered = TemplateRenderer.render(
            template: template,
            vars: ["Dependencies": dependencies]
        )
        return ("\(dir)/event-generator-config.yaml", rendered.output, "eventGeneratorConfig")
    }
}
