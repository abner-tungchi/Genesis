import Foundation

public enum BundleParser {

    public static func parseMinimal(at url: URL) throws -> MinimalBundle {
        let envelope = try loadEnvelope(at: url)
        let (manifestVersion, bundleId, context) = try validateCore(envelope)
        return MinimalBundle(manifestVersion: manifestVersion, bundleId: bundleId, context: context)
    }

    public static func parseFull(at url: URL) throws -> FullBundle {
        let envelope = try loadEnvelope(at: url)
        let (manifestVersion, bundleId, context) = try validateCore(envelope)

        guard let rawAggregates = envelope.aggregates, !rawAggregates.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "bundle has no aggregates")
        }

        let aggregates = try rawAggregates.enumerated().map { idx, raw -> AggregateSpec in
            try decodeAggregateSpec(raw, idx: idx)
        }

        let useCases = try (envelope.useCases ?? []).enumerated().map { idx, raw -> UseCaseSpec in
            try decodeUseCaseSpec(raw, idx: idx)
        }

        let rawDtos = try (envelope.dtos ?? []).enumerated().map { idx, raw -> DtoSpec in
            try decodeDtoSpec(raw, idx: idx, manifestVersion: manifestVersion)
        }

        let readModels = try (envelope.readModels ?? []).enumerated().map { idx, raw -> ReadModelSpec in
            try decodeReadModelSpec(raw, idx: idx, aggregates: aggregates)
        }

        // Phase 1.l.1.1: canonicalize perReadModel DTOs' readModelRef via dtoSpecRef cross-ref
        let dtos = canonicalizeDtoReadModelRefs(
            rawDtos,
            envelopeReadModels: envelope.readModels ?? [],
            decodedReadModels: readModels
        )

        let presenters = try (envelope.presenters ?? []).enumerated().map { idx, raw -> PresenterSpec in
            try decodePresenterSpec(raw, idx: idx)
        }

        let aggregateIds = Set(aggregates.map { $0.aggregateSpecId })
        for (i, uc) in useCases.enumerated() {
            if !aggregateIds.contains(uc.aggregateSpecId) {
                throw GenesisError.bundleInvalid(
                    reason: "useCases[\(i)] references unknown aggregateSpecId '\(uc.aggregateSpecId)'"
                )
            }
            if let aggregate = aggregates.first(where: { $0.aggregateSpecId == uc.aggregateSpecId }) {
                if !aggregate.eventNames.contains(uc.emittedEvent) {
                    throw GenesisError.bundleInvalid(
                        reason: "useCases[\(i)] emits '\(uc.emittedEvent)' "
                            + "but aggregate '\(aggregate.name)' does not declare it in events[]"
                    )
                }
            }
        }

        // Phase 1.k.2: presenter ↔ readModel validation pass (audit H1+M1+M2 fixes)
        try validatePresentersAgainstReadModels(
            presenters: presenters,
            readModels: readModels,
            aggregates: aggregates
        )

        return FullBundle(
            manifestVersion: manifestVersion,
            bundleId: bundleId,
            context: context,
            aggregates: aggregates,
            useCases: useCases,
            dtos: dtos,
            readModels: readModels,
            presenters: presenters
        )
    }

    private struct Envelope: Decodable {
        let manifestVersion: Int?
        let bundleId: String?
        let context: String?
        let aggregates: [RawAggregate]?
        let useCases: [RawUseCase]?
        let dtos: [RawDto]?
        let readModels: [RawReadModel]?
        let presenters: [RawPresenter]?
    }

    private struct RawReadModel: Decodable {
        let readModelSpecId: String?
        let aggregateSpecId: String?
        let aggregateRef: String?
        let name: String?
        let queryName: String?      // Phase 1.l.1: Cosmogony alias for `name`
        // events 支援三種 schema:
        //   1. events: [{name, sourceAggregate}]  (v1 /readmodel skill new shape)
        //   2. events: [{name}]                    (legacy aggregate.events shape)
        //   3. events: [String]                    (legacy flat string array)
        let events: [RawReadModelEvent]?
        let eventsFlat: [String]?
        let eventNames: [String]?
        let key: RawReadModelKey?
        let parameters: [RawReadModelParameter]?  // Phase 1.l.1: Cosmogony — derive key from parameters[0]
        let returnType: RawReadModelReturnType?    // Phase 1.l.1: Cosmogony — flatten into storedFields
        let links: [RawReadModelLink]?              // Phase 1.l.1: Cosmogony — derive events from outbound DomainEvent
        let storedFields: [RawReadModelStoredField]?
        let comment: String?

        private enum CodingKeys: String, CodingKey {
            case readModelSpecId, aggregateSpecId, aggregateRef, name, queryName,
                 events, eventNames, key, parameters, returnType, links,
                 storedFields, comment
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.readModelSpecId = try c.decodeIfPresent(String.self, forKey: .readModelSpecId)
            self.aggregateSpecId = try c.decodeIfPresent(String.self, forKey: .aggregateSpecId)
            self.aggregateRef = try c.decodeIfPresent(String.self, forKey: .aggregateRef)
            self.name = try c.decodeIfPresent(String.self, forKey: .name)
            self.queryName = try c.decodeIfPresent(String.self, forKey: .queryName)
            self.eventNames = try c.decodeIfPresent([String].self, forKey: .eventNames)
            self.key = try c.decodeIfPresent(RawReadModelKey.self, forKey: .key)
            self.parameters = try c.decodeIfPresent([RawReadModelParameter].self, forKey: .parameters)
            self.returnType = try c.decodeIfPresent(RawReadModelReturnType.self, forKey: .returnType)
            self.links = try c.decodeIfPresent([RawReadModelLink].self, forKey: .links)
            self.storedFields = try c.decodeIfPresent([RawReadModelStoredField].self, forKey: .storedFields)
            self.comment = try c.decodeIfPresent(String.self, forKey: .comment)
            // events: try [RawReadModelEvent] (objects) first, fall back to [String]
            if let objs = try? c.decodeIfPresent([RawReadModelEvent].self, forKey: .events) {
                self.events = objs
                self.eventsFlat = nil
            } else if let strs = try? c.decodeIfPresent([String].self, forKey: .events) {
                self.events = nil
                self.eventsFlat = strs
            } else {
                self.events = nil
                self.eventsFlat = nil
            }
        }
    }

    private struct RawReadModelEvent: Decodable {
        let name: String?
        let sourceAggregate: String?
    }

    private struct RawReadModelKey: Decodable {
        let field: String?
        let type: String?
        let fromEventPayload: String?
    }

    private struct RawReadModelStoredField: Decodable {
        let name: String?
        let type: String?
        let `default`: String?
    }

    /// Phase 1.l.1: Cosmogony returnType.fields lacks `default`; supply sensible primitive defaults
    /// at flatten time. Returns nil for non-primitive types (downstream auto-infers collections /
    /// throws bundleInvalid if no inference possible).
    private static func inferDefaultForPrimitive(_ rawType: String) -> String? {
        switch rawType.trimmingCharacters(in: .whitespaces) {
        case "String": return "\"\""
        case "Int", "Decimal", "Float", "Double": return "0"
        case "Bool": return "false"
        default: return nil  // let downstream handle collection / optional / custom type
        }
    }

    // Phase 1.l.1: Cosmogony schema adapter types
    private struct RawReadModelLink: Decodable {
        let direction: String?    // "outbound" | "inbound"
        let targetType: String?   // "DomainEvent" | "Aggregate" | ...
        let targetName: String?
        let targetSpecId: String?
    }

    private struct RawReadModelParameter: Decodable {
        let name: String?
        let type: String?
    }

    private struct RawReadModelReturnType: Decodable {
        let shape: String?  // "object" | ...
        let fields: [RawReadModelReturnField]?
    }

    private struct RawReadModelReturnField: Decodable {
        let name: String?
        let type: String?
        let dtoSpecRef: String?  // Cosmogony stable id, Genesis ignores
    }

    private static func loadEnvelope(at url: URL) throws -> Envelope {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !exists {
            throw GenesisError.bundleNotFound(url)
        }
        if isDirectory.boolValue {
            throw GenesisError.bundleInvalid(reason: "path is a directory, not a JSON file: \(url.path)")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GenesisError.fileSystemFailed(operation: "read bundle", underlying: error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw GenesisError.bundleInvalid(reason: "JSON malformed: \(error.localizedDescription)")
        }
    }

    private static func validateCore(_ envelope: Envelope) throws -> (Int, String, String) {
        guard let manifestVersion = envelope.manifestVersion else {
            throw GenesisError.bundleInvalid(reason: "missing required key: manifestVersion")
        }
        guard let bundleId = envelope.bundleId, !bundleId.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "missing or empty required key: bundleId")
        }
        guard let context = envelope.context, !context.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "missing or empty required key: context")
        }
        return (manifestVersion, bundleId, context)
    }

    private struct RawAggregate: Decodable {
        let aggregateSpecId: String?
        let aggregate: String?
        let identity: RawIdentity?
        let state: [RawField]?
        let invariants: [RawInvariant]?
        let events: [RawEventRef]?
    }

    private struct RawIdentity: Decodable {
        let name: String?
    }

    private struct RawField: Decodable {
        let name: String?
        let type: String?
    }

    private struct RawInvariant: Decodable {
        let id: String?
        let name: String?
        let title: String?
        let errorCode: String?
        let rules: [RawInvariantRule]?
        let status: String?
    }

    private struct RawInvariantRule: Decodable {
        let when: String?
        let rule: String?
    }

    private struct RawEventRef: Decodable {
        let name: String?
    }

    private struct RawUseCase: Decodable {
        let useCaseSpecId: String?
        let aggregateSpecId: String?
        let useCase: String?
        let aggregate: String?
        let input: [RawField]?
        let emittedEvent: String?
        let eventPayload: [RawField]?
        let preconditions: [RawPrecondition]?
    }

    private struct RawPrecondition: Decodable {
        let text: String?
    }

    private struct RawDto: Decodable {
        let dtoSpecId: String?
        let name: String?
        let description: String?
        let fields: [RawField]?
        // Phase 1.h: schema extension (audit M3 — use `dtoKind` to avoid clash with legacy `kind: "DtoSpec"` marker)
        let dtoKind: String?
        let cases: [String]?
        let domainTypeName: String?
        let isContextShared: Bool?
        let aggregateRef: String?
        // Phase 1.l.1.1: Cosmogony v19 schema — explicit scope/usage routing
        let scope: String?
        let usage: String?
        let useCaseRef: String?
        let readModelRef: String?
    }

    // Phase 2: /presenter skill v1 — RawPresenter for bundle.presenters[]
    private struct RawPresenter: Decodable {
        let presenterSpecId: String?
        let name: String?
        let readModelRef: String?
        let aggregateRef: String?
        let input: RawPresenterInput?
        let output: RawPresenterOutput?
        let endpoint: RawPresenterEndpoint?
        let comment: String?
    }

    private struct RawPresenterInput: Decodable {
        let fields: [RawPresenterInputField]?
    }

    private struct RawPresenterInputField: Decodable {
        let name: String?
        let type: String?
        let fromPath: String?
    }

    private struct RawPresenterOutput: Decodable {
        let kind: String?
        let elementType: String?
        let elementSource: String?
        let isOptional: Bool?
    }

    private struct RawPresenterEndpoint: Decodable {
        let path: String?
        let method: String?
    }

    private static func decodeAggregateSpec(_ raw: RawAggregate, idx: Int) throws -> AggregateSpec {
        guard let aggregateSpecId = raw.aggregateSpecId, !aggregateSpecId.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "aggregates[\(idx)] missing required key 'aggregateSpecId'")
        }
        guard let name = raw.aggregate, !name.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "aggregates[\(idx)] missing required key 'aggregate'")
        }
        guard let identityName = raw.identity?.name, !identityName.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "aggregates[\(idx)] missing required key 'identity.name'")
        }
        let state = try (raw.state ?? []).enumerated().map { fIdx, f -> FieldSpec in
            try decodeField(f, prefix: "aggregates[\(idx)].state[\(fIdx)]")
        }
        let invariants = try (raw.invariants ?? []).enumerated().map { iIdx, inv -> InvariantSpec in
            try decodeInvariant(inv, prefix: "aggregates[\(idx)].invariants[\(iIdx)]")
        }
        let eventNames = (raw.events ?? []).compactMap { $0.name }
        return AggregateSpec(
            aggregateSpecId: aggregateSpecId,
            name: name,
            identityName: identityName,
            state: state,
            invariants: invariants,
            eventNames: eventNames
        )
    }

    private static func decodeField(_ raw: RawField, prefix: String) throws -> FieldSpec {
        guard let name = raw.name, !name.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "\(prefix) missing required key 'name'")
        }
        guard let type = raw.type, !type.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "\(prefix) missing required key 'type'")
        }
        return FieldSpec(name: name, rawType: type)
    }

    private static func decodeInvariant(_ raw: RawInvariant, prefix: String) throws -> InvariantSpec {
        guard let id = raw.id, !id.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "\(prefix) missing required key 'id'")
        }
        guard let name = raw.name, !name.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "\(prefix) missing required key 'name'")
        }
        guard let errorCode = raw.errorCode, !errorCode.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "\(prefix) missing required key 'errorCode'")
        }
        let rules = (raw.rules ?? []).map { InvariantRule(when: $0.when ?? "", rule: $0.rule ?? "") }
        return InvariantSpec(
            id: id,
            name: name,
            title: raw.title ?? "",
            errorCode: errorCode,
            rules: rules,
            status: raw.status ?? ""
        )
    }

    private static func decodeUseCaseSpec(_ raw: RawUseCase, idx: Int) throws -> UseCaseSpec {
        guard let useCaseSpecId = raw.useCaseSpecId, !useCaseSpecId.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "useCases[\(idx)] missing required key 'useCaseSpecId'")
        }
        guard let aggregateSpecId = raw.aggregateSpecId, !aggregateSpecId.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "useCases[\(idx)] missing required key 'aggregateSpecId'")
        }
        guard let useCase = raw.useCase, !useCase.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "useCases[\(idx)] missing required key 'useCase'")
        }
        guard let aggregate = raw.aggregate, !aggregate.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "useCases[\(idx)] missing required key 'aggregate'")
        }
        guard let emittedEvent = raw.emittedEvent, !emittedEvent.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "useCases[\(idx)] missing required key 'emittedEvent'")
        }
        let input = try (raw.input ?? []).enumerated().map { fIdx, f in
            try decodeField(f, prefix: "useCases[\(idx)].input[\(fIdx)]")
        }
        let payload = try (raw.eventPayload ?? []).enumerated().map { fIdx, f in
            try decodeField(f, prefix: "useCases[\(idx)].eventPayload[\(fIdx)]")
        }
        let preconditions = (raw.preconditions ?? []).compactMap { $0.text }
        return UseCaseSpec(
            useCaseSpecId: useCaseSpecId,
            aggregateSpecId: aggregateSpecId,
            useCase: useCase,
            aggregate: aggregate,
            input: input,
            emittedEvent: emittedEvent,
            eventPayload: payload,
            preconditions: preconditions
        )
    }

    private static func decodeReadModelSpec(
        _ raw: RawReadModel,
        idx: Int,
        aggregates: [AggregateSpec]
    ) throws -> ReadModelSpec {
        // Phase 1.l.1: Cosmogony adapter — name with queryName alias fallback
        // Cosmogony uses lowerCamelCase for queryName; normalize to UpperCamelCase since
        // Genesis downstream (ReadModelRenderer) treats name as a Swift type prefix.
        let name: String
        if let n = raw.name, !n.isEmpty {
            name = n  // legacy `name` path assumed already PascalCase
        } else if let qn = raw.queryName, !qn.isEmpty {
            name = qn.prefix(1).uppercased() + qn.dropFirst()
        } else {
            throw GenesisError.bundleInvalid(
                reason: "readModels[\(idx)] missing required key 'name' (or 'queryName' Cosmogony alias)"
            )
        }
        // Phase 2: readModelSpecId 改 optional，缺則 derive from name
        let readModelSpecId = raw.readModelSpecId ?? "rm-\(name)"

        let eventNames: [String]
        let eventRefs: [ReadModelEventRef]
        if let refs = raw.events {
            eventNames = refs.compactMap { $0.name }
            eventRefs = refs.compactMap { ref -> ReadModelEventRef? in
                guard let n = ref.name, !n.isEmpty else { return nil }
                guard let src = ref.sourceAggregate, !src.isEmpty else { return nil }
                return ReadModelEventRef(name: n, sourceAggregate: src)
            }
        } else if let flat = raw.eventsFlat {
            eventNames = flat
            eventRefs = []
        } else if let alt = raw.eventNames {
            eventNames = alt
            eventRefs = []
        } else if let links = raw.links, !links.isEmpty {
            // Phase 1.l.1: Cosmogony adapter — derive events from outbound DomainEvent links
            let outbound = links.filter { $0.direction == "outbound" && $0.targetType == "DomainEvent" }
            let derived: [ReadModelEventRef] = try outbound.compactMap { link -> ReadModelEventRef? in
                guard let eventName = link.targetName, !eventName.isEmpty else { return nil }
                // Cross-ref: find which aggregate declares this event
                guard let agg = aggregates.first(where: { $0.eventNames.contains(eventName) }) else {
                    throw GenesisError.bundleInvalid(
                        reason: "readModels[\(idx)] ('\(name)') links to DomainEvent "
                              + "'\(eventName)' but no aggregate declares it in events[]"
                    )
                }
                return ReadModelEventRef(name: eventName, sourceAggregate: agg.name)
            }
            eventNames = derived.map(\.name)
            eventRefs = derived
        } else {
            // Legacy minimal fixture path: 允許空 events（與 readmodels-bundle.json 對齊）
            eventNames = []
            eventRefs = []
        }

        let key: ReadModelKey?
        if let rawKey = raw.key,
           let f = rawKey.field, !f.isEmpty,
           let t = rawKey.type, !t.isEmpty,
           let p = rawKey.fromEventPayload, !p.isEmpty {
            key = ReadModelKey(field: f, type: t, fromEventPayload: p)
        } else if let params = raw.parameters, let first = params.first,
                  let fName = first.name, !fName.isEmpty,
                  let fType = first.type, !fType.isEmpty {
            // Phase 1.l.1: Cosmogony adapter — derive key from parameters[0]
            FileHandle.standardError.write(Data(
                ("⚠ ReadModel '\(name)': derived key from parameters[0] '\(fName)'; "
                + "verify fromEventPayload assumption (parameter name == event payload field name)\n").utf8
            ))
            key = ReadModelKey(field: fName, type: fType, fromEventPayload: fName)
        } else {
            key = nil
        }

        let existingSF: [ReadModelStoredField] = (raw.storedFields ?? []).compactMap { f -> ReadModelStoredField? in
            guard let n = f.name, !n.isEmpty else { return nil }
            guard let t = f.type, !t.isEmpty else { return nil }
            return ReadModelStoredField(name: n, type: t, defaultValue: f.default)
        }
        let storedFields: [ReadModelStoredField]
        if !existingSF.isEmpty {
            storedFields = existingSF
        } else if let rt = raw.returnType, let rtFields = rt.fields, !rtFields.isEmpty {
            // Phase 1.l.1: Cosmogony adapter — flatten returnType.fields → storedFields.
            // Cosmogony returnType doesn't carry `default`; for primitives supply sensible
            // default; for collections keep non-Optional (empty default inferred); for custom types (likely DTO) mark Optional (nil default auto-inferred
            // by ReadModelRenderer). Consistent with how aggregate state is treated.
            storedFields = rtFields.compactMap { f -> ReadModelStoredField? in
                guard let n = f.name, !n.isEmpty else { return nil }
                guard let t = f.type, !t.isEmpty else { return nil }
                if let primDefault = inferDefaultForPrimitive(t) {
                    return ReadModelStoredField(name: n, type: t, defaultValue: primDefault)
                } else if (isCollectionType(t) || t.hasPrefix("Set[")) && !t.hasSuffix("?") {
                    // Collections stay non-Optional (ReadModelRenderer infers `[]` / `Set()` / `[:]`): a canvas
                    // `Array[String]` return field must line up with a presenter array Output (`[String]`),
                    // otherwise `return readModel.<field>` fails to compile against `[String]?`.
                    return ReadModelStoredField(name: n, type: t, defaultValue: nil)
                } else {
                    // Wrap non-primitive in Optional — DTOs / custom types default to nil
                    return ReadModelStoredField(name: n, type: "\(t)?", defaultValue: nil)
                }
            }
        } else {
            storedFields = []
        }

        // Phase 1.l.1.1 Option A: derive aggregateRef from eventRefs when explicit ref is missing.
        // Cosmogony v19 doesn't emit readModel.aggregateRef (v20 will). Genesis can derive it
        // from eventRefs[*].sourceAggregate when all events share the same owning aggregate.
        // This prevents downstream renderers (Presenter / ContextProjectionModel) from treating
        // single-aggregate readModels as context-level (which would split projector files).
        let derivedAggregateRef: String?
        if let explicit = raw.aggregateRef, !explicit.isEmpty {
            derivedAggregateRef = explicit
        } else if !eventRefs.isEmpty {
            let sourceAggs = Set(eventRefs.map { $0.sourceAggregate })
            if sourceAggs.count == 1, let single = sourceAggs.first {
                derivedAggregateRef = single
                FileHandle.standardError.write(Data(
                    ("⚠ ReadModel '\(name)': aggregateRef derived as '\(single)' from eventRefs[*].sourceAggregate "
                    + "(Cosmogony v20 will provide explicit aggregateRef)\n").utf8
                ))
            } else {
                // Genuinely cross-aggregate readModel — leave aggregateRef nil for context-level placement
                derivedAggregateRef = nil
            }
        } else {
            derivedAggregateRef = nil
        }

        return ReadModelSpec(
            readModelSpecId: readModelSpecId,
            aggregateSpecId: raw.aggregateSpecId,
            name: name,
            eventNames: eventNames,
            aggregateRef: derivedAggregateRef,
            key: key,
            storedFields: storedFields,
            eventRefs: eventRefs,
            comment: raw.comment
        )
    }

    private static func decodeDtoSpec(_ raw: RawDto, idx: Int, manifestVersion: Int) throws -> DtoSpec {
        guard let dtoSpecId = raw.dtoSpecId, !dtoSpecId.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "dtos[\(idx)] missing required key 'dtoSpecId'")
        }
        guard let name = raw.name, !name.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "dtos[\(idx)] missing required key 'name'")
        }

        // Phase 1.p D5: reserved-name filter — prevent DTO names colliding with Genesis-internal artifacts.
        if name.hasSuffix("ApiError")
            || name.hasPrefix("ApiComponents+")
            || name.hasSuffix("+Schema")
            || name.hasSuffix("+Domain") {
            throw GenesisError.bundleInvalid(
                reason: "dtos[\(idx)].name '\(name)' collides with reserved infra pattern "
                      + "('*ApiError' / 'ApiComponents+*' / '*+Schema' / '*+Domain'); rename DTO"
            )
        }

        // Phase 1.p D20 (supersedes D11): strict gate on manifestVersion >= 2.
        // When Cosmogony v22 ships manifestVersion: 2, scope becomes required.
        // For current v19/v20 (manifestVersion: 1), scope stays optional (inference path).
        if manifestVersion >= 2 && (raw.scope == nil || raw.scope?.isEmpty == true) {
            throw GenesisError.bundleInvalid(
                reason: "dtos[\(idx)] missing required key 'scope' under manifestVersion: \(manifestVersion) strict path"
            )
        }

        // Phase 1.p D9 + D19: forbidden scope × usage combinations.
        // Raise loud bundleInvalid with actionable hint instead of silent emit-broken-code.
        switch (raw.scope, raw.usage) {
        case ("perUseCase", "response"):
            throw GenesisError.bundleInvalid(
                reason: "dtos[\(idx)] perUseCase × response is unusual; use contextShared or aggregate response scope, "
                      + "or file an OC counterexample to lift this restriction (Phase 1.p D9)"
            )
        case ("perReadModel", "request"):
            throw GenesisError.bundleInvalid(
                reason: "dtos[\(idx)] perReadModel × request not supported (queries have no request body); "
                      + "use scope=perUseCase for write-side input DTOs (Phase 1.p D19)"
            )
        case ("perReadModel", "both"):
            throw GenesisError.bundleInvalid(
                reason: "dtos[\(idx)] perReadModel × both not supported (queries are response-only); "
                      + "use usage=response (Phase 1.p D19)"
            )
        case ("contextShared", "request"):
            throw GenesisError.bundleInvalid(
                reason: "dtos[\(idx)] contextShared × request write-DTO not supported in Phase 1.p; "
                      + "deferred to Phase 1.q"
            )
        default:
            break
        }

        let fields = try (raw.fields ?? []).enumerated().map { fIdx, f in
            try decodeField(f, prefix: "dtos[\(idx)].fields[\(fIdx)]")
        }
        return DtoSpec(
            dtoSpecId: dtoSpecId,
            name: name,
            description: raw.description ?? "",
            fields: fields,
            dtoKind: raw.dtoKind,
            cases: raw.cases ?? [],
            domainTypeName: raw.domainTypeName,
            isContextShared: raw.isContextShared,
            aggregateRef: raw.aggregateRef,
            scope: raw.scope,
            usage: raw.usage,
            useCaseRef: raw.useCaseRef,
            readModelRef: raw.readModelRef
        )
    }

    /// Phase 1.l.1.1: cross-ref canonicalize for DTOs with scope=perReadModel.
    /// Cosmogony bundle's `dto.readModelRef` may be lowerCamelCase or user-typo'd
    /// (e.g. `getPromissions` vs `getPermissions`). But every readModel.returnType.fields[]
    /// that uses a DTO carries `dtoSpecRef: <dto.dtoSpecId>` — that's the stable cross-ref.
    /// Resolve readModelRef to the canonical readModel.name via dtoSpecRef when available.
    private static func canonicalizeDtoReadModelRefs(
        _ dtos: [DtoSpec],
        envelopeReadModels: [RawReadModel],
        decodedReadModels: [ReadModelSpec]
    ) -> [DtoSpec] {
        // Build dtoSpecRef → canonical readModel name lookup
        var specIdToRMName: [String: String] = [:]
        for (rmIdx, rawRm) in envelopeReadModels.enumerated() {
            guard rmIdx < decodedReadModels.count else { continue }
            let canonicalName = decodedReadModels[rmIdx].name
            for f in rawRm.returnType?.fields ?? [] {
                if let specRef = f.dtoSpecRef, !specRef.isEmpty {
                    specIdToRMName[specRef] = canonicalName
                }
            }
        }

        return dtos.map { dto -> DtoSpec in
            guard dto.scope == "perReadModel" else { return dto }
            guard let canonical = specIdToRMName[dto.dtoSpecId] else { return dto }
            // Only overwrite if different — preserve dto.readModelRef when no cross-ref typo
            guard let current = dto.readModelRef,
                  current.lowercased() != canonical.lowercased() else { return dto }
            // Typo'd cross-ref detected — canonicalize via dtoSpecRef
            FileHandle.standardError.write(Data(
                ("⚠ DTO '\(dto.name)': readModelRef '\(current)' canonicalized to '\(canonical)' "
                + "via dtoSpecRef cross-ref (user typo in canvas)\n").utf8
            ))
            return DtoSpec(
                dtoSpecId: dto.dtoSpecId,
                name: dto.name,
                description: dto.description,
                fields: dto.fields,
                dtoKind: dto.dtoKind,
                cases: dto.cases,
                domainTypeName: dto.domainTypeName,
                isContextShared: dto.isContextShared,
                aggregateRef: dto.aggregateRef,
                scope: dto.scope,
                usage: dto.usage,
                useCaseRef: dto.useCaseRef,
                readModelRef: canonical
            )
        }
    }

    // MARK: - Phase 1.k.2 presenter ↔ readModel validations

    /// audit M2 — strip optional + trim, then detect collection prefixes.
    private static func isCollectionType(_ raw: String) -> Bool {
        var t = raw.trimmingCharacters(in: .whitespaces)
        // Strip trailing `?` (optional) — `Set<X>?` is still a collection.
        while t.hasSuffix("?") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[")
            || t.hasPrefix("Set<")
            || t.hasPrefix("Array<")
            || t.hasPrefix("Array[")
            || t.hasPrefix("Dictionary<")
            || t.hasPrefix("Dictionary[")
    }

    /// audit M1 — resolve readModel's effective aggregateRef.
    /// nil aggregateRef + aggregateSpecId → resolve to aggregate.name; both nil → throw (only when presenter references this readModel).
    private static func resolvedReadModelAggregateRef(
        _ rm: ReadModelSpec,
        aggregates: [AggregateSpec]
    ) throws -> String {
        if let ref = rm.aggregateRef { return ref }
        if let specId = rm.aggregateSpecId,
           let agg = aggregates.first(where: { $0.aggregateSpecId == specId }) {
            return agg.name
        }
        throw GenesisError.bundleInvalid(
            reason: "readModel '\(rm.name)' has neither aggregateRef nor resolvable aggregateSpecId; cannot be used by presenter"
        )
    }

    private static func validatePresentersAgainstReadModels(
        presenters: [PresenterSpec],
        readModels: [ReadModelSpec],
        aggregates: [AggregateSpec]
    ) throws {
        // (a) readModel name uniqueness (audit H1)
        var seen: Set<String> = []
        for rm in readModels {
            if !seen.insert(rm.name).inserted {
                throw GenesisError.bundleInvalid(
                    reason: "duplicate readModel name '\(rm.name)'; readModel names must be unique within a bundle"
                )
            }
        }

        // Skip remaining checks if no presenters (per-agg-only bundles unaffected by Phase 1.k.2).
        guard !presenters.isEmpty else { return }

        // (b) readModelRef must exist (audit H1) — build lookup
        let readModelsByName = Dictionary(uniqueKeysWithValues: readModels.map { ($0.name, $0) })

        for p in presenters {
            guard let rm = readModelsByName[p.readModelRef] else {
                throw GenesisError.bundleInvalid(
                    reason: "presenter '\(p.name)' references missing readModel '\(p.readModelRef)'"
                )
            }

            // (c) D1 consistency — presenter.aggregateRef must match resolved readModel aggregateRef
            let resolved = try resolvedReadModelAggregateRef(rm, aggregates: aggregates)
            if p.aggregateRef != resolved {
                throw GenesisError.bundleInvalid(
                    reason: "presenter '\(p.name)' aggregateRef '\(p.aggregateRef)' does not match "
                        + "readModelRef '\(p.readModelRef)' aggregateRef '\(resolved)' "
                        + "(must be co-located per Phase 1.k.2 D1)"
                )
            }

            // (d) D4 scalar + collection elementType reject (audit M2 boundary handling)
            if p.output.kind == .scalar && isCollectionType(p.output.elementType) {
                throw GenesisError.bundleInvalid(
                    reason: "presenter '\(p.name)' scalar output cannot use collection elementType "
                        + "'\(p.output.elementType)'; use kind=array or change elementType"
                )
            }
        }
    }

    private static func decodePresenterSpec(_ raw: RawPresenter, idx: Int) throws -> PresenterSpec {
        guard let name = raw.name, !name.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "presenters[\(idx)] missing required key 'name'")
        }
        guard let readModelRef = raw.readModelRef, !readModelRef.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "presenters[\(idx)] missing required key 'readModelRef'")
        }
        guard let aggregateRef = raw.aggregateRef, !aggregateRef.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "presenters[\(idx)] missing required key 'aggregateRef'")
        }
        let presenterSpecId = raw.presenterSpecId ?? "p-\(name)"

        let inputFields: [PresenterInputField] = (raw.input?.fields ?? []).compactMap { f -> PresenterInputField? in
            guard let n = f.name, !n.isEmpty else { return nil }
            guard let t = f.type, !t.isEmpty else { return nil }
            return PresenterInputField(name: n, type: t, fromPath: f.fromPath ?? n)
        }

        guard let outputRaw = raw.output,
              let kindStr = outputRaw.kind,
              let kind = PresenterOutputKind(rawValue: kindStr) else {
            throw GenesisError.bundleInvalid(reason: "presenters[\(idx)] missing or invalid 'output.kind' (must be 'array' | 'single' | 'scalar')")
        }
        guard let elementType = outputRaw.elementType, !elementType.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "presenters[\(idx)] missing 'output.elementType'")
        }
        guard let elementSource = outputRaw.elementSource, !elementSource.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "presenters[\(idx)] missing 'output.elementSource'")
        }
        let output = PresenterOutput(
            kind: kind,
            elementType: elementType,
            elementSource: elementSource,
            isOptional: outputRaw.isOptional ?? false
        )

        let endpoint = PresenterEndpoint(
            path: raw.endpoint?.path ?? "/\(name.lowercased())",
            method: raw.endpoint?.method ?? "GET"
        )

        return PresenterSpec(
            presenterSpecId: presenterSpecId,
            name: name,
            readModelRef: readModelRef,
            aggregateRef: aggregateRef,
            input: PresenterInput(fields: inputFields),
            output: output,
            endpoint: endpoint,
            comment: raw.comment
        )
    }
}
