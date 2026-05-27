import XCTest
@testable import GenesisCore

final class TypeOwnershipResolverTests: XCTestCase {
    func testTier1ExplicitContextShared() {
        let dto = makeDto(name: "EmployeeStatus", isContextShared: true)
        let bundle = makeBundle(dtos: [dto])

        let result = TypeOwnershipResolver.resolve(bundle: bundle, adapter: defaultAdapter())

        XCTAssertEqual(result.ownership["EmployeeStatus"], .contextShared)
        XCTAssertFalse(result.warnings.contains { $0.contains("EmployeeStatus") })
    }

    func testTier1ExplicitOwnedByValidAgg() {
        let aggregate = makeAggregate(name: "Employee", stateFields: [])
        let dto = makeDto(name: "EmployeeStatus", isContextShared: false, aggregateRef: "Employee")
        let bundle = makeBundle(aggregates: [aggregate], dtos: [dto])

        let result = TypeOwnershipResolver.resolve(bundle: bundle, adapter: defaultAdapter())

        XCTAssertEqual(result.ownership["EmployeeStatus"], .ownedBy(aggregateName: "Employee"))
        XCTAssertFalse(result.warnings.contains { $0.contains("EmployeeStatus") })
    }

    func testTier1InvalidAggregateRefFallsBackToTier2() {
        let aggregate = makeAggregate(name: "Employee", stateFields: [("status", "EmployeeStatus")])
        let dto = makeDto(name: "EmployeeStatus", isContextShared: false, aggregateRef: "NotExisting")
        let bundle = makeBundle(aggregates: [aggregate], dtos: [dto])

        let result = TypeOwnershipResolver.resolve(bundle: bundle, adapter: defaultAdapter())

        XCTAssertEqual(result.ownership["EmployeeStatus"], .ownedBy(aggregateName: "Employee"))
        XCTAssertTrue(
            result.warnings.contains { $0.contains("aggregateRef 'NotExisting' not found") },
            "warnings: \(result.warnings)"
        )
    }

    func testTier2ZeroRefsDefaultContextShared() {
        let dto = makeDto(name: "EmployeeStatus")
        let bundle = makeBundle(dtos: [dto])

        let result = TypeOwnershipResolver.resolve(bundle: bundle, adapter: defaultAdapter())

        XCTAssertEqual(result.ownership["EmployeeStatus"], .contextShared)
        XCTAssertTrue(
            result.warnings.contains { $0.contains("EmployeeStatus") && $0.contains("no usage detected") },
            "warnings: \(result.warnings)"
        )
    }

    func testTier2OneRefAutoDetectAgg() {
        let aggregate = makeAggregate(name: "Employee", stateFields: [("status", "EmployeeStatus")])
        let dto = makeDto(name: "EmployeeStatus")
        let bundle = makeBundle(aggregates: [aggregate], dtos: [dto])

        let result = TypeOwnershipResolver.resolve(bundle: bundle, adapter: defaultAdapter())

        XCTAssertEqual(result.ownership["EmployeeStatus"], .ownedBy(aggregateName: "Employee"))
        XCTAssertTrue(
            result.warnings.contains { $0.contains("EmployeeStatus") && $0.contains("auto-detected as Employee") },
            "warnings: \(result.warnings)"
        )
    }

    func testTier2MultipleRefsAutoShared() {
        let aggB = makeAggregate(name: "AggB", stateFields: [("status", "EmployeeStatus")])
        let aggA = makeAggregate(name: "AggA", stateFields: [("status", "EmployeeStatus")])
        let dto = makeDto(name: "EmployeeStatus")
        let bundle = makeBundle(aggregates: [aggB, aggA], dtos: [dto])

        let result = TypeOwnershipResolver.resolve(bundle: bundle, adapter: defaultAdapter())

        XCTAssertEqual(result.ownership["EmployeeStatus"], .contextShared)
        let warning = result.warnings.first { $0.contains("EmployeeStatus") && $0.contains("auto-shared from") }
        XCTAssertNotNil(warning, "warnings: \(result.warnings)")
        XCTAssertTrue(warning?.contains("auto-shared from 2 aggregates (AggA, AggB)") == true)
        XCTAssertLessThan(
            warning?.range(of: "AggA")?.lowerBound ?? warning!.endIndex,
            warning?.range(of: "AggB")?.lowerBound ?? warning!.startIndex
        )
    }

    func testExtractTypeNameWrappers() {
        let wrappers = ["Set<X>", "[X]", "Array<X>", "Optional<X>", "X?", "X"]

        for rawType in wrappers {
            let aggregate = makeAggregate(name: "Employee", stateFields: [("value", rawType)])
            let bundle = makeBundle(aggregates: [aggregate], dtos: [makeDto(name: "X")])

            let result = TypeOwnershipResolver.resolve(bundle: bundle, adapter: defaultAdapter())

            XCTAssertEqual(
                result.ownership["X"],
                .ownedBy(aggregateName: "Employee"),
                "rawType: \(rawType), warnings: \(result.warnings)"
            )
        }
    }

    func testExtractTypeNameNoSubstringMatch() {
        let aggregate = makeAggregate(name: "Employee", stateFields: [("status", "EmployeeStatusKind")])
        let dto = makeDto(name: "EmployeeStatus")
        let bundle = makeBundle(aggregates: [aggregate], dtos: [dto])

        let result = TypeOwnershipResolver.resolve(bundle: bundle, adapter: defaultAdapter())

        XCTAssertEqual(result.ownership["EmployeeStatus"], .contextShared)
        XCTAssertTrue(
            result.warnings.contains { $0.contains("EmployeeStatus") && $0.contains("no usage detected") },
            "warnings: \(result.warnings)"
        )
    }

    func testAdapterCustomTypeGoesTier2() {
        let aggregate = makeAggregate(name: "Employee", stateFields: [("code", "EmployeeCode")])
        let bundle = makeBundle(aggregates: [aggregate])
        let adapter = Adapter(
            adapterVersion: 1,
            schemaVersion: 1,
            contextName: "TestContext",
            bundleId: nil,
            typeMapping: [:],
            customTypes: [CustomTypeSpec(name: "EmployeeCode", kind: .valueObject, underlying: "String")],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .direct, wrapper: nil)
        )

        let result = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)

        XCTAssertEqual(result.ownership["EmployeeCode"], .ownedBy(aggregateName: "Employee"))
        XCTAssertTrue(result.warnings.contains { $0.contains("EmployeeCode") }, "warnings: \(result.warnings)")
    }

    func testDeterminism() {
        let aggB = makeAggregate(name: "AggB", stateFields: [("shared", "SharedStatus"), ("custom", "CustomCode")])
        let aggA = makeAggregate(name: "AggA", stateFields: [("shared", "SharedStatus"), ("local", "LocalStatus")])
        let bundle = makeBundle(
            aggregates: [aggB, aggA],
            dtos: [
                makeDto(name: "ExplicitShared", isContextShared: true),
                makeDto(name: "ExplicitOwned", isContextShared: false, aggregateRef: "AggA"),
                makeDto(name: "LocalStatus"),
                makeDto(name: "SharedStatus"),
                makeDto(name: "OrphanStatus"),
            ]
        )
        let adapter = Adapter(
            adapterVersion: 1,
            schemaVersion: 1,
            contextName: "TestContext",
            bundleId: nil,
            typeMapping: [:],
            customTypes: [CustomTypeSpec(name: "CustomCode", kind: .identifier, underlying: "String")],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .direct, wrapper: nil)
        )

        let first = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let second = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)

        XCTAssertEqual(first.ownership, second.ownership)
        XCTAssertEqual(first.warnings, second.warnings)
    }

    private func makeDto(
        name: String,
        isContextShared: Bool? = nil,
        aggregateRef: String? = nil
    ) -> DtoSpec {
        DtoSpec(
            dtoSpecId: "dto-\(name)",
            name: name,
            description: "",
            fields: [],
            isContextShared: isContextShared,
            aggregateRef: aggregateRef
        )
    }

    private func makeAggregate(name: String, stateFields: [(String, String)]) -> AggregateSpec {
        AggregateSpec(
            aggregateSpecId: "agg-\(name)",
            name: name,
            identityName: "\(name.lowercased())Id",
            state: stateFields.map { FieldSpec(name: $0.0, rawType: $0.1) },
            invariants: [],
            eventNames: []
        )
    }

    private func makeBundle(
        aggregates: [AggregateSpec] = [],
        useCases: [UseCaseSpec] = [],
        dtos: [DtoSpec] = [],
        presenters: [PresenterSpec] = [],
        readModels: [ReadModelSpec] = []
    ) -> FullBundle {
        FullBundle(
            manifestVersion: 1,
            bundleId: "test",
            context: "TestContext",
            aggregates: aggregates,
            useCases: useCases,
            dtos: dtos,
            readModels: readModels,
            presenters: presenters
        )
    }

    private func defaultAdapter() -> Adapter { .defaultFor(contextName: "TestContext") }
}
