import XCTest
@testable import GenesisCore

final class SwiftTypeResolverAdapterTests: XCTestCase {
    func testTypeMappingOverridesContainerLogic() throws {
        let adapter = Adapter(
            adapterVersion: 1, schemaVersion: 1, contextName: "X", bundleId: nil,
            typeMapping: ["Array[String]": "OrderedSet<String>"],
            customTypes: [],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .direct, wrapper: nil)
        )
        let resolved = try SwiftTypeResolver.resolve(
            rawType: "Array[String]", knownCustomTypes: [], adapter: adapter
        )
        XCTAssertEqual(resolved, "OrderedSet<String>", "typeMapping must win over default Array[] container handling")
    }

    func testNoMappingFallsThroughToDefault() throws {
        let adapter = Adapter.defaultFor(contextName: "X")
        let resolved = try SwiftTypeResolver.resolve(
            rawType: "Array[String]", knownCustomTypes: [], adapter: adapter
        )
        XCTAssertEqual(resolved, "[String]")
    }

    func testCustomTypeFromAdapterRecognizedViaKnownCustomTypes() throws {
        let adapter = Adapter.defaultFor(contextName: "X")
        let resolved = try SwiftTypeResolver.resolve(
            rawType: "EmailAddress", knownCustomTypes: ["EmailAddress"], adapter: adapter
        )
        XCTAssertEqual(resolved, "EmailAddress")
    }
}
