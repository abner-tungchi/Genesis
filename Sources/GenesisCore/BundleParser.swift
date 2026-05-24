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

        let dtos = try (envelope.dtos ?? []).enumerated().map { idx, raw -> DtoSpec in
            try decodeDtoSpec(raw, idx: idx)
        }

        let readModels = try (envelope.readModels ?? []).enumerated().map { idx, raw -> ReadModelSpec in
            try decodeReadModelSpec(raw, idx: idx)
        }

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
        // events 支援三種 schema:
        //   1. events: [{name, sourceAggregate}]  (v1 /readmodel skill new shape)
        //   2. events: [{name}]                    (legacy aggregate.events shape)
        //   3. events: [String]                    (legacy flat string array)
        let events: [RawReadModelEvent]?
        let eventsFlat: [String]?
        let eventNames: [String]?
        let key: RawReadModelKey?
        let storedFields: [RawReadModelStoredField]?
        let comment: String?

        private enum CodingKeys: String, CodingKey {
            case readModelSpecId, aggregateSpecId, aggregateRef, name,
                 events, eventNames, key, storedFields, comment
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.readModelSpecId = try c.decodeIfPresent(String.self, forKey: .readModelSpecId)
            self.aggregateSpecId = try c.decodeIfPresent(String.self, forKey: .aggregateSpecId)
            self.aggregateRef = try c.decodeIfPresent(String.self, forKey: .aggregateRef)
            self.name = try c.decodeIfPresent(String.self, forKey: .name)
            self.eventNames = try c.decodeIfPresent([String].self, forKey: .eventNames)
            self.key = try c.decodeIfPresent(RawReadModelKey.self, forKey: .key)
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

    private static func decodeReadModelSpec(_ raw: RawReadModel, idx: Int) throws -> ReadModelSpec {
        guard let name = raw.name, !name.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "readModels[\(idx)] missing required key 'name'")
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
        } else {
            key = nil
        }

        let storedFields: [ReadModelStoredField] = (raw.storedFields ?? []).compactMap { f -> ReadModelStoredField? in
            guard let n = f.name, !n.isEmpty else { return nil }
            guard let t = f.type, !t.isEmpty else { return nil }
            return ReadModelStoredField(name: n, type: t, defaultValue: f.default)
        }

        return ReadModelSpec(
            readModelSpecId: readModelSpecId,
            aggregateSpecId: raw.aggregateSpecId,
            name: name,
            eventNames: eventNames,
            aggregateRef: raw.aggregateRef,
            key: key,
            storedFields: storedFields,
            eventRefs: eventRefs,
            comment: raw.comment
        )
    }

    private static func decodeDtoSpec(_ raw: RawDto, idx: Int) throws -> DtoSpec {
        guard let dtoSpecId = raw.dtoSpecId, !dtoSpecId.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "dtos[\(idx)] missing required key 'dtoSpecId'")
        }
        guard let name = raw.name, !name.isEmpty else {
            throw GenesisError.bundleInvalid(reason: "dtos[\(idx)] missing required key 'name'")
        }
        let fields = try (raw.fields ?? []).enumerated().map { fIdx, f in
            try decodeField(f, prefix: "dtos[\(idx)].fields[\(fIdx)]")
        }
        // Backwards-compat: legacy DTOs (no Phase 1.h fields) default isContextShared=true,
        // preserving Phase 1.b/1.c/1.f behavior of emitting all bundle.dtos[] to {Ctx}Shared.
        // Explicit Phase 1.h entries (with dtoKind or isContextShared) honor the explicit value.
        let hasPhase1hSchema = raw.dtoKind != nil || raw.isContextShared != nil
        let resolvedIsContextShared = raw.isContextShared ?? (hasPhase1hSchema ? false : true)
        return DtoSpec(
            dtoSpecId: dtoSpecId,
            name: name,
            description: raw.description ?? "",
            fields: fields,
            dtoKind: raw.dtoKind,
            cases: raw.cases ?? [],
            domainTypeName: raw.domainTypeName,
            isContextShared: resolvedIsContextShared
        )
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
