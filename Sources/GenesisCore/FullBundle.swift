import Foundation

public struct FullBundle: Sendable, Equatable, Encodable {
    public let manifestVersion: Int
    public let bundleId: String
    public let context: String
    public let aggregates: [AggregateSpec]
    public let useCases: [UseCaseSpec]
    public let dtos: [DtoSpec]
    public let readModels: [ReadModelSpec]
    public let presenters: [PresenterSpec]

    /// All identifiers that Swift codegen should recognize as DTO-derived types.
    /// Includes both `dto.name` (wire type) and `dto.domainTypeName` (domain type) when distinct.
    /// Phase 1.l.1: supports Cosmogony schema where DTO wraps a separately-named domain type.
    public var dtoTypeNames: Set<String> {
        var names = Set<String>()
        for dto in dtos {
            names.insert(dto.name)
            if let dtn = dto.domainTypeName, !dtn.isEmpty {
                names.insert(dtn)
            }
        }
        return names
    }

    public init(
        manifestVersion: Int,
        bundleId: String,
        context: String,
        aggregates: [AggregateSpec],
        useCases: [UseCaseSpec],
        dtos: [DtoSpec],
        readModels: [ReadModelSpec] = [],
        presenters: [PresenterSpec] = []
    ) {
        self.manifestVersion = manifestVersion
        self.bundleId = bundleId
        self.context = context
        self.aggregates = aggregates
        self.useCases = useCases
        self.dtos = dtos
        self.readModels = readModels
        self.presenters = presenters
    }
}

public struct ReadModelSpec: Sendable, Equatable, Encodable {
    public let readModelSpecId: String
    public let aggregateSpecId: String?
    public let name: String
    public let eventNames: [String]
    // Phase 2 (/readmodel skill v1) — extended schema for bundle-writing skill.
    // All extra fields optional to keep backwards-compat with legacy minimal fixtures.
    public let aggregateRef: String?
    public let key: ReadModelKey?
    public let storedFields: [ReadModelStoredField]
    public let eventRefs: [ReadModelEventRef]
    public let comment: String?

    public init(
        readModelSpecId: String,
        aggregateSpecId: String?,
        name: String,
        eventNames: [String],
        aggregateRef: String? = nil,
        key: ReadModelKey? = nil,
        storedFields: [ReadModelStoredField] = [],
        eventRefs: [ReadModelEventRef] = [],
        comment: String? = nil
    ) {
        self.readModelSpecId = readModelSpecId
        self.aggregateSpecId = aggregateSpecId
        self.name = name
        self.eventNames = eventNames
        self.aggregateRef = aggregateRef
        self.key = key
        self.storedFields = storedFields
        self.eventRefs = eventRefs
        self.comment = comment
    }
}

public struct ReadModelKey: Sendable, Equatable, Encodable {
    public let field: String
    public let type: String
    public let fromEventPayload: String

    public init(field: String, type: String, fromEventPayload: String) {
        self.field = field
        self.type = type
        self.fromEventPayload = fromEventPayload
    }
}

public struct ReadModelStoredField: Sendable, Equatable, Encodable {
    public let name: String
    public let type: String
    public let defaultValue: String?

    public init(name: String, type: String, defaultValue: String? = nil) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
    }
}

public struct ReadModelEventRef: Sendable, Equatable, Encodable {
    public let name: String
    public let sourceAggregate: String

    public init(name: String, sourceAggregate: String) {
        self.name = name
        self.sourceAggregate = sourceAggregate
    }
}

public struct AggregateSpec: Sendable, Equatable, Encodable {
    public let aggregateSpecId: String
    public let name: String
    public let identityName: String
    public let state: [FieldSpec]
    public let invariants: [InvariantSpec]
    public let eventNames: [String]

    public init(
        aggregateSpecId: String,
        name: String,
        identityName: String,
        state: [FieldSpec],
        invariants: [InvariantSpec],
        eventNames: [String]
    ) {
        self.aggregateSpecId = aggregateSpecId
        self.name = name
        self.identityName = identityName
        self.state = state
        self.invariants = invariants
        self.eventNames = eventNames
    }
}

public struct UseCaseSpec: Sendable, Equatable, Encodable {
    public let useCaseSpecId: String
    public let aggregateSpecId: String
    public let useCase: String
    public let aggregate: String
    public let input: [FieldSpec]
    public let emittedEvent: String
    public let eventPayload: [FieldSpec]
    public let preconditions: [String]

    public init(
        useCaseSpecId: String,
        aggregateSpecId: String,
        useCase: String,
        aggregate: String,
        input: [FieldSpec],
        emittedEvent: String,
        eventPayload: [FieldSpec],
        preconditions: [String]
    ) {
        self.useCaseSpecId = useCaseSpecId
        self.aggregateSpecId = aggregateSpecId
        self.useCase = useCase
        self.aggregate = aggregate
        self.input = input
        self.emittedEvent = emittedEvent
        self.eventPayload = eventPayload
        self.preconditions = preconditions
    }
}

public struct DtoSpec: Sendable, Equatable, Encodable {
    public let dtoSpecId: String
    public let name: String
    public let description: String
    public let fields: [FieldSpec]
    // Phase 1.h: extended schema for ApiRenderer DTO mapper codegen.
    public let dtoKind: String?              // "enum" | "struct" | "union" (legacy nil → description-based inference)
    public let cases: [String]               // for dtoKind="enum"
    public let domainTypeName: String?       // domain type for mapper (default: strip "Dto" suffix from name)
    public let isContextShared: Bool?        // Phase 1.n: nil = no explicit marking, resolver Tier 2 介入; non-nil = explicit Tier 1
    public let aggregateRef: String?         // Phase 1.n: explicit per-agg ownership marker (used when isContextShared == false)
    // Phase 1.l.1.1: Cosmogony v19 schema — explicit scope/usage routing
    public let scope: String?                // "aggregate" | "perUseCase" | "perReadModel" | "contextShared"
    public let usage: String?                // "request" | "response" | "both"
    public let useCaseRef: String?           // for scope=perUseCase
    public let readModelRef: String?         // for scope=perReadModel; canonicalized by BundleParser via dtoSpecRef

    public init(
        dtoSpecId: String,
        name: String,
        description: String,
        fields: [FieldSpec],
        dtoKind: String? = nil,
        cases: [String] = [],
        domainTypeName: String? = nil,
        isContextShared: Bool? = nil,
        aggregateRef: String? = nil,
        scope: String? = nil,
        usage: String? = nil,
        useCaseRef: String? = nil,
        readModelRef: String? = nil
    ) {
        self.dtoSpecId = dtoSpecId
        self.name = name
        self.description = description
        self.fields = fields
        self.dtoKind = dtoKind
        self.cases = cases
        self.domainTypeName = domainTypeName
        self.isContextShared = isContextShared
        self.aggregateRef = aggregateRef
        self.scope = scope
        self.usage = usage
        self.useCaseRef = useCaseRef
        self.readModelRef = readModelRef
    }
}

public struct FieldSpec: Sendable, Equatable, Encodable {
    public let name: String
    public let rawType: String

    public init(name: String, rawType: String) {
        self.name = name
        self.rawType = rawType
    }
}

public struct InvariantSpec: Sendable, Equatable, Encodable {
    public let id: String
    public let name: String
    public let title: String
    public let errorCode: String
    public let rules: [InvariantRule]
    public let status: String

    public init(
        id: String,
        name: String,
        title: String,
        errorCode: String,
        rules: [InvariantRule],
        status: String
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.errorCode = errorCode
        self.rules = rules
        self.status = status
    }
}

public struct InvariantRule: Sendable, Equatable, Encodable {
    public let when: String
    public let rule: String

    public init(when: String, rule: String) {
        self.when = when
        self.rule = rule
    }
}

// MARK: - PresenterSpec (/presenter skill v1)

public struct PresenterSpec: Sendable, Equatable, Encodable {
    public let presenterSpecId: String
    public let name: String
    public let readModelRef: String
    public let aggregateRef: String
    public let input: PresenterInput
    public let output: PresenterOutput
    public let endpoint: PresenterEndpoint
    public let comment: String?

    public init(
        presenterSpecId: String,
        name: String,
        readModelRef: String,
        aggregateRef: String,
        input: PresenterInput,
        output: PresenterOutput,
        endpoint: PresenterEndpoint,
        comment: String? = nil
    ) {
        self.presenterSpecId = presenterSpecId
        self.name = name
        self.readModelRef = readModelRef
        self.aggregateRef = aggregateRef
        self.input = input
        self.output = output
        self.endpoint = endpoint
        self.comment = comment
    }
}

public struct PresenterInput: Sendable, Equatable, Encodable {
    public let fields: [PresenterInputField]
    public init(fields: [PresenterInputField]) {
        self.fields = fields
    }
}

public struct PresenterInputField: Sendable, Equatable, Encodable {
    public let name: String
    public let type: String
    public let fromPath: String
    public init(name: String, type: String, fromPath: String) {
        self.name = name
        self.type = type
        self.fromPath = fromPath
    }
}

public enum PresenterOutputKind: String, Sendable, Equatable, Encodable {
    case array, single, scalar
}

public struct PresenterOutput: Sendable, Equatable, Encodable {
    public let kind: PresenterOutputKind
    public let elementType: String
    public let elementSource: String
    public let isOptional: Bool
    public init(kind: PresenterOutputKind, elementType: String, elementSource: String, isOptional: Bool = false) {
        self.kind = kind
        self.elementType = elementType
        self.elementSource = elementSource
        self.isOptional = isOptional
    }
}

public struct PresenterEndpoint: Sendable, Equatable, Encodable {
    public let path: String
    public let method: String  // "GET" v1
    public init(path: String, method: String = "GET") {
        self.path = path
        self.method = method
    }
}
