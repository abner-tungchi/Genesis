import Foundation

public struct Adapter: Sendable, Equatable {
    public let adapterVersion: Int
    public let schemaVersion: Int
    public let contextName: String
    public let bundleId: String?
    public let typeMapping: [String: String]
    public let customTypes: [CustomTypeSpec]
    public let createdEventOverrides: [String: String]
    public let aggregateSplit: AggregateSplitSpec
    public let idStrategy: IdStrategySpec

    public init(
        adapterVersion: Int,
        schemaVersion: Int,
        contextName: String,
        bundleId: String?,
        typeMapping: [String: String],
        customTypes: [CustomTypeSpec],
        createdEventOverrides: [String: String],
        aggregateSplit: AggregateSplitSpec,
        idStrategy: IdStrategySpec
    ) {
        self.adapterVersion = adapterVersion
        self.schemaVersion = schemaVersion
        self.contextName = contextName
        self.bundleId = bundleId
        self.typeMapping = typeMapping
        self.customTypes = customTypes
        self.createdEventOverrides = createdEventOverrides
        self.aggregateSplit = aggregateSplit
        self.idStrategy = idStrategy
    }

    public static func defaultFor(contextName: String) -> Adapter {
        Adapter(
            adapterVersion: 1,
            schemaVersion: 1,
            contextName: contextName,
            bundleId: nil,
            typeMapping: [:],
            customTypes: [],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .direct, wrapper: nil)
        )
    }
}

public struct CustomTypeSpec: Sendable, Equatable {
    public let name: String
    public let kind: Kind
    public let underlying: String?
    public let cases: [String]?

    public enum Kind: String, Sendable, Codable {
        case valueObject
        case `enum`
        case identifier
    }

    public init(name: String, kind: Kind, underlying: String? = nil, cases: [String]? = nil) {
        self.name = name
        self.kind = kind
        self.underlying = underlying
        self.cases = cases
    }
}

public struct AggregateSplitSpec: Sendable, Equatable {
    public let strategy: String
    public let rootMap: [String: String]

    public init(strategy: String, rootMap: [String: String]) {
        self.strategy = strategy
        self.rootMap = rootMap
    }
}

public struct IdStrategySpec: Sendable, Equatable {
    public let kind: Kind
    public let wrapper: String?

    public enum Kind: String, Sendable, Codable {
        case direct
        case typedStruct
    }

    public init(kind: Kind, wrapper: String?) {
        self.kind = kind
        self.wrapper = wrapper
    }
}
