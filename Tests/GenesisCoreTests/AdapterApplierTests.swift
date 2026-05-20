import XCTest
@testable import GenesisCore

final class AdapterApplierTests: XCTestCase {
    private func makeAgg(name: String = "Foo", id: String = "agg-1") -> AggregateSpec {
        AggregateSpec(
            aggregateSpecId: id,
            name: name,
            identityName: "fooId",
            state: [],
            invariants: [],
            eventNames: ["fooCreated", "fooEdited"]
        )
    }

    private func makeUC(name: String, agg: AggregateSpec, emits: String) -> UseCaseSpec {
        UseCaseSpec(
            useCaseSpecId: "uc-\(name)",
            aggregateSpecId: agg.aggregateSpecId,
            useCase: name,
            aggregate: agg.name,
            input: [],
            emittedEvent: emits,
            eventPayload: [],
            preconditions: []
        )
    }

    func testValidateRejectsUnknownAggregateInOverride() throws {
        let agg = makeAgg()
        let bundle = FullBundle(
            manifestVersion: 1, bundleId: "b", context: "X",
            aggregates: [agg], useCases: [], dtos: []
        )
        var adapter = Adapter.defaultFor(contextName: "X")
        adapter = Adapter(
            adapterVersion: 1, schemaVersion: 1, contextName: "X", bundleId: nil,
            typeMapping: [:], customTypes: [],
            createdEventOverrides: ["Unknown": "anything"],
            aggregateSplit: adapter.aggregateSplit, idStrategy: adapter.idStrategy
        )
        XCTAssertThrowsError(try AdapterApplier.validate(adapter: adapter, bundle: bundle))
    }

    func testResolveCreatedUseCaseHonorsOverride() throws {
        let agg = makeAgg(name: "Foo")
        let uc1 = makeUC(name: "registerFoo", agg: agg, emits: "fooCreated")
        let uc2 = makeUC(name: "editFoo", agg: agg, emits: "fooEdited")
        let adapter = Adapter(
            adapterVersion: 1, schemaVersion: 1, contextName: "X", bundleId: nil,
            typeMapping: [:], customTypes: [],
            createdEventOverrides: ["Foo": "registerFoo"],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .direct, wrapper: nil)
        )
        let resolved = try AdapterApplier.resolveCreatedUseCase(for: agg, useCases: [uc1, uc2], adapter: adapter)
        XCTAssertEqual(resolved.useCase, "registerFoo")
    }

    func testFallbackChainStillWorksWithoutOverride() throws {
        let agg = makeAgg(name: "UserAccessProfile")
        let uc1 = makeUC(name: "createUserAccessProfile", agg: agg, emits: "userAccessProfileCreated")
        let uc2 = makeUC(name: "grantPrivilege", agg: agg, emits: "privilegeGranted")
        let adapter = Adapter.defaultFor(contextName: "X")
        let resolved = try AdapterApplier.resolveCreatedUseCase(for: agg, useCases: [uc1, uc2], adapter: adapter)
        XCTAssertEqual(resolved.useCase, "createUserAccessProfile")
    }

    func testTypedStructReturnsNilAndWarnsDeprecation() {
        // Phase 1.e: typedStruct is deprecated (gradyzhuo kit enforces ID == String).
        // resolveIdWrapperName must return nil and emit a stderr deprecation warning.
        let agg = makeAgg(name: "UserAccessProfile")
        let adapter = Adapter(
            adapterVersion: 1, schemaVersion: 1, contextName: "X", bundleId: nil,
            typeMapping: [:], customTypes: [],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .typedStruct, wrapper: "{Aggregate}ID")
        )
        XCTAssertNil(AdapterApplier.resolveIdWrapperName(for: agg, adapter: adapter))
        // Note: stderr warning is captured by integration tests; here we just verify the nil contract.
    }

    func testResolveIdWrapperNilForDirectStrategy() {
        let agg = makeAgg(name: "Foo")
        let adapter = Adapter.defaultFor(contextName: "X")
        XCTAssertNil(AdapterApplier.resolveIdWrapperName(for: agg, adapter: adapter))
    }
}
