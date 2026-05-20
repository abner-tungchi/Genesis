import Foundation

/// Errors raised by `ReadModelBundleAppender.append`.
public enum ReadModelAppendError: Error, Equatable, CustomStringConvertible {
    case invalidName(String, reason: String)
    case duplicateName(String)
    case unknownAggregate(String)
    case emptyEvents
    case unknownEvent(String, aggregate: String)
    case unknownSourceAggregate(String)
    case inconsistentPayloadKey([String: String])
    case invalidKey(String)
    case storedFieldCollidesWithKey(String)

    public var description: String {
        switch self {
        case .invalidName(let name, let reason):
            return "invalid readmodel name '\(name)': \(reason)"
        case .duplicateName(let name):
            return "duplicate readmodel name '\(name)' already exists in bundle"
        case .unknownAggregate(let ref):
            return "aggregateRef '\(ref)' not found in bundle.aggregates[] (and not '<context-level>')"
        case .emptyEvents:
            return "selected events list cannot be empty"
        case .unknownEvent(let name, let agg):
            return "event '\(name)' not declared in aggregate '\(agg)' events[]"
        case .unknownSourceAggregate(let src):
            return "sourceAggregate '\(src)' not found in bundle.aggregates[]"
        case .inconsistentPayloadKey(let map):
            let pairs = map.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            return "inconsistent payload key across selected events (\(pairs)); v1 requires shared key"
        case .invalidKey(let reason):
            return "invalid key: \(reason)"
        case .storedFieldCollidesWithKey(let name):
            return "storedField '\(name)' collides with key.field; remove or rename"
        }
    }
}

/// User answers collected by the `/readmodel` skill across its 6 steps.
public struct ReadModelAnswers: Sendable, Equatable, Codable {
    public let aggregateRef: String          // bundle aggregate name OR "<context-level>"
    public let selectedEvents: [SelectedEvent]
    public let name: String                   // Get<Noun>
    public let keyField: String               // ReadModel id-backing field name
    public let keyType: String                // String / UUID / Int / Int64
    public let keyFromPayload: String         // event payload field for linkTo key
    public let storedFields: [StoredFieldChoice]
    public let comment: String?
    public let overwriteIfExists: Bool

    public init(
        aggregateRef: String,
        selectedEvents: [SelectedEvent],
        name: String,
        keyField: String,
        keyType: String,
        keyFromPayload: String,
        storedFields: [StoredFieldChoice],
        comment: String? = nil,
        overwriteIfExists: Bool = false
    ) {
        self.aggregateRef = aggregateRef
        self.selectedEvents = selectedEvents
        self.name = name
        self.keyField = keyField
        self.keyType = keyType
        self.keyFromPayload = keyFromPayload
        self.storedFields = storedFields
        self.comment = comment
        self.overwriteIfExists = overwriteIfExists
    }

    public struct SelectedEvent: Sendable, Equatable, Codable {
        public let name: String
        public let sourceAggregate: String
        public init(name: String, sourceAggregate: String) {
            self.name = name
            self.sourceAggregate = sourceAggregate
        }
    }

    public struct StoredFieldChoice: Sendable, Equatable, Codable {
        public let name: String
        public let type: String
        public let defaultValue: String?

        private enum CodingKeys: String, CodingKey {
            case name, type
            case defaultValue = "default"
        }

        public init(name: String, type: String, defaultValue: String? = nil) {
            self.name = name
            self.type = type
            self.defaultValue = defaultValue
        }
    }
}

public enum ReadModelBundleAppender {

    /// Allowed v1 key types per spec §Field validation rules.
    public static let allowedKeyTypes: [String] = ["String", "UUID", "Int", "Int64"]

    /// Append a new readmodel entry to bundle.readModels[].
    ///
    /// - throws `ReadModelAppendError` on validation failure (no partial mutation).
    /// - returns a new FullBundle with the new entry appended (or replacing on overwrite).
    public static func append(
        bundle: FullBundle,
        answers: ReadModelAnswers
    ) throws -> FullBundle {
        try validateName(answers.name)
        try validateAggregateRef(answers.aggregateRef, bundle: bundle)
        try validateEvents(answers, bundle: bundle)
        try validateKey(answers, bundle: bundle)
        try validateStoredFields(answers)

        // Duplicate detection
        let collision = bundle.readModels.first(where: { $0.name == answers.name })
        if collision != nil && !answers.overwriteIfExists {
            throw ReadModelAppendError.duplicateName(answers.name)
        }

        // Build entry
        let eventRefs = answers.selectedEvents.map {
            ReadModelEventRef(name: $0.name, sourceAggregate: $0.sourceAggregate)
        }
        let storedFields = answers.storedFields.map {
            ReadModelStoredField(name: $0.name, type: $0.type, defaultValue: $0.defaultValue)
        }
        let key = ReadModelKey(
            field: answers.keyField,
            type: answers.keyType,
            fromEventPayload: answers.keyFromPayload
        )
        let entry = ReadModelSpec(
            readModelSpecId: "rm-\(answers.name)",
            aggregateSpecId: aggregateSpecId(for: answers.aggregateRef, in: bundle),
            name: answers.name,
            eventNames: answers.selectedEvents.map(\.name),
            aggregateRef: answers.aggregateRef,
            key: key,
            storedFields: storedFields,
            eventRefs: eventRefs,
            comment: answers.comment
        )

        // Append OR overwrite
        var newRMs = bundle.readModels
        if let idx = newRMs.firstIndex(where: { $0.name == answers.name }) {
            newRMs[idx] = entry
        } else {
            newRMs.append(entry)
        }

        return FullBundle(
            manifestVersion: bundle.manifestVersion,
            bundleId: bundle.bundleId,
            context: bundle.context,
            aggregates: bundle.aggregates,
            useCases: bundle.useCases,
            dtos: bundle.dtos,
            readModels: newRMs
        )
    }

    // MARK: - Payload resolution (spec §Event payload resolution algorithm)

    /// Resolve an event's payload field names. Pass-1: direct on aggregate.events[]
    /// (not modeled in current FullBundle — always returns []); Pass-2: via useCases[]
    /// matched by emittedEvent; Pass-3: empty fallback.
    ///
    /// Bundle today carries payloads only via useCases[].eventPayload (Pass-2). When
    /// schema gains aggregate.events[].payload directly, this function gains a Pass-1.
    public static func resolvePayload(eventName: String, bundle: FullBundle) -> [FieldSpec] {
        // Pass-1: aggregate.events[].payload — not in current FullBundle; skip.
        // Pass-2: useCases[].eventPayload via emittedEvent join
        if let uc = bundle.useCases.first(where: { $0.emittedEvent == eventName }) {
            return uc.eventPayload
        }
        // Pass-3: no payload info available
        return []
    }

    // MARK: - Private validators

    private static func validateName(_ name: String) throws {
        let pattern = "^Get[A-Z][A-Za-z0-9]+$"
        let re = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: name.utf16.count)
        if re.firstMatch(in: name, range: range) == nil {
            throw ReadModelAppendError.invalidName(
                name,
                reason: "must match \(pattern) (Get + PascalCase noun)"
            )
        }
    }

    private static func validateAggregateRef(_ ref: String, bundle: FullBundle) throws {
        if ref == "<context-level>" { return }
        let known = Set(bundle.aggregates.map(\.name))
        if !known.contains(ref) {
            throw ReadModelAppendError.unknownAggregate(ref)
        }
    }

    private static func validateEvents(_ answers: ReadModelAnswers, bundle: FullBundle) throws {
        if answers.selectedEvents.isEmpty {
            throw ReadModelAppendError.emptyEvents
        }
        // Each event.sourceAggregate must exist; event must be declared by that aggregate.
        for ev in answers.selectedEvents {
            guard let agg = bundle.aggregates.first(where: { $0.name == ev.sourceAggregate }) else {
                throw ReadModelAppendError.unknownSourceAggregate(ev.sourceAggregate)
            }
            if !agg.eventNames.contains(ev.name) {
                throw ReadModelAppendError.unknownEvent(ev.name, aggregate: agg.name)
            }
        }
        // If aggregateRef is a specific aggregate (not context-level), all events must come from it.
        if answers.aggregateRef != "<context-level>" {
            let mismatches = answers.selectedEvents.filter { $0.sourceAggregate != answers.aggregateRef }
            if !mismatches.isEmpty {
                throw ReadModelAppendError.unknownEvent(
                    mismatches.first!.name,
                    aggregate: answers.aggregateRef
                )
            }
        }
    }

    private static func validateKey(_ answers: ReadModelAnswers, bundle: FullBundle) throws {
        let kfPattern = "^[a-z][A-Za-z0-9]*$"
        let re = try NSRegularExpression(pattern: kfPattern)
        let r = NSRange(location: 0, length: answers.keyField.utf16.count)
        if answers.keyField.isEmpty || re.firstMatch(in: answers.keyField, range: r) == nil {
            throw ReadModelAppendError.invalidKey("field must match \(kfPattern); got '\(answers.keyField)'")
        }
        if !allowedKeyTypes.contains(answers.keyType) {
            throw ReadModelAppendError.invalidKey(
                "type '\(answers.keyType)' not in allowed v1 set \(allowedKeyTypes)"
            )
        }
        if answers.keyFromPayload.isEmpty {
            throw ReadModelAppendError.invalidKey("fromEventPayload must be non-empty")
        }
        // Strict v1: keyFromPayload must appear in every selected event's resolved payload.
        // If payload resolution returns [] for some event, treat as "skip strict check" (user manually entered key).
        var inconsistent: [String: String] = [:]
        for ev in answers.selectedEvents {
            let payload = resolvePayload(eventName: ev.name, bundle: bundle)
            if payload.isEmpty { continue }  // payload schema absent — manual entry path
            let fieldNames = Set(payload.map(\.name))
            if !fieldNames.contains(answers.keyFromPayload) {
                inconsistent[ev.name] = "missing '\(answers.keyFromPayload)' in payload \(fieldNames.sorted())"
            }
        }
        if !inconsistent.isEmpty {
            throw ReadModelAppendError.inconsistentPayloadKey(inconsistent)
        }
    }

    private static func validateStoredFields(_ answers: ReadModelAnswers) throws {
        let nameSet = Set(answers.storedFields.map(\.name))
        if nameSet.contains(answers.keyField) {
            throw ReadModelAppendError.storedFieldCollidesWithKey(answers.keyField)
        }
        if nameSet.count != answers.storedFields.count {
            throw ReadModelAppendError.invalidKey("storedFields[].name must be unique")
        }
        let pattern = "^[a-z][A-Za-z0-9]*$"
        let re = try NSRegularExpression(pattern: pattern)
        for f in answers.storedFields {
            let r = NSRange(location: 0, length: f.name.utf16.count)
            if f.name.isEmpty || re.firstMatch(in: f.name, range: r) == nil {
                throw ReadModelAppendError.invalidName(
                    f.name,
                    reason: "storedFields[].name must match \(pattern)"
                )
            }
            if f.type.isEmpty {
                throw ReadModelAppendError.invalidName(
                    f.name,
                    reason: "storedFields[].type must be non-empty"
                )
            }
        }
    }

    private static func aggregateSpecId(for aggregateRef: String, in bundle: FullBundle) -> String? {
        if aggregateRef == "<context-level>" { return nil }
        return bundle.aggregates.first(where: { $0.name == aggregateRef })?.aggregateSpecId
    }
}
