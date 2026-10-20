import XCTest
@testable import GenesisCore

final class PresenterRendererTests: XCTestCase {

    private func minimalAggregate(name: String = "AuditQuoting") -> AggregateSpec {
        AggregateSpec(
            aggregateSpecId: "agg-1", name: name,
            identityName: "auditQuotingId", state: [], invariants: [],
            eventNames: ["Created"]
        )
    }

    private func minimalReadModel() -> ReadModelSpec {
        ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: "agg-1",
            name: "GetThings", eventNames: ["Created"],
            aggregateRef: "AuditQuoting",
            key: ReadModelKey(field: "auditQuotingId", type: "String", fromEventPayload: "auditQuotingId"),
            storedFields: [],
            eventRefs: [ReadModelEventRef(name: "Created", sourceAggregate: "AuditQuoting")],
            comment: nil
        )
    }

    private func presenter(
        name: String = "GetThings",
        aggregateRef: String = "AuditQuoting",
        kind: PresenterOutputKind = .array,
        elementType: String = "ThingDto",
        elementSource: String = "things",
        isOptional: Bool = false
    ) -> PresenterSpec {
        PresenterSpec(
            presenterSpecId: "p-\(name)",
            name: name,
            readModelRef: name,
            aggregateRef: aggregateRef,
            input: PresenterInput(fields: [
                PresenterInputField(name: "auditQuotingId", type: "String", fromPath: "auditQuotingId")
            ]),
            output: PresenterOutput(
                kind: kind, elementType: elementType,
                elementSource: elementSource, isOptional: isOptional
            ),
            endpoint: PresenterEndpoint(path: "/audit-quoting/{auditQuotingId}/things", method: "GET"),
            comment: nil
        )
    }

    private func bundleWith(presenters: [PresenterSpec]) -> FullBundle {
        FullBundle(
            manifestVersion: 1, bundleId: "t", context: "AuditQuotingContext",
            aggregates: [minimalAggregate()],
            useCases: [], dtos: [],
            readModels: [minimalReadModel()],
            presenters: presenters
        )
    }

    // MARK: - Output type derivation

    func testOutputTypeArray() {
        let out = PresenterOutput(kind: .array, elementType: "FooDto", elementSource: "foos", isOptional: false)
        XCTAssertEqual(PresenterRenderer.outputType(for: out), "[FooDto]")
    }

    func testOutputTypeSingleNonOptional() {
        let out = PresenterOutput(kind: .single, elementType: "FooDto", elementSource: "foo", isOptional: false)
        XCTAssertEqual(PresenterRenderer.outputType(for: out), "FooDto")
    }

    func testOutputTypeSingleOptional() {
        let out = PresenterOutput(kind: .single, elementType: "FooDto", elementSource: "foo", isOptional: true)
        XCTAssertEqual(PresenterRenderer.outputType(for: out), "FooDto?")
    }

    func testOutputTypeScalarOptional() {
        let out = PresenterOutput(kind: .scalar, elementType: "String", elementSource: "name", isOptional: true)
        XCTAssertEqual(PresenterRenderer.outputType(for: out), "String?")
    }

    // MARK: - Happy paths

    func testHappyPathArrayEmits() throws {
        let bundle = bundleWith(presenters: [presenter()])
        let outputs = try PresenterRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext",
            adapter: .defaultFor(contextName: "AuditQuotingContext")
        )
        XCTAssertEqual(outputs.count, 1)
        let f = outputs[0]
        XCTAssertEqual(f.path, "Sources/AuditQuotingAggregate/Adapter/GetThings/GetThingsApplicationService.swift")
        XCTAssertEqual(f.role, "presenterApplicationService")
        XCTAssertTrue(f.content.contains("package struct GetThingsApplicationService: ApplicationService"))
        XCTAssertTrue(f.content.contains("kdbClient: KurrentDBClient"))
        XCTAssertTrue(f.content.contains("typealias Output = [ThingDto]"))
        XCTAssertTrue(f.content.contains("TODO(/presenter-fill skill)"))
        XCTAssertTrue(f.content.contains("fatalError"))
        XCTAssertFalse(f.content.contains("repository"), "read-side uses kdbClient, not repository")
    }

    func testInputFieldCosmogonyArrayNotationResolved() throws {
        let p = PresenterSpec(
            presenterSpecId: "p-x", name: "GetThings", readModelRef: "GetThings",
            aggregateRef: "AuditQuoting",
            input: PresenterInput(fields: [
                PresenterInputField(name: "ids", type: "Array[String]", fromPath: "ids"),
            ]),
            output: PresenterOutput(kind: .array, elementType: "ThingDto", elementSource: "things"),
            endpoint: PresenterEndpoint(path: "/things", method: "GET"),
            comment: nil
        )
        let outputs = try PresenterRenderer.render(
            bundle: bundleWith(presenters: [p]), contextName: "AuditQuotingContext",
            adapter: .defaultFor(contextName: "AuditQuotingContext")
        )
        let c = outputs[0].content
        XCTAssertTrue(c.contains("ids: [String]"), c)
        XCTAssertFalse(c.contains("Array["), c)
    }

    func testHappyPathSingleOptional() throws {
        let p = presenter(kind: .single, elementType: "FooDto", isOptional: true)
        let outputs = try PresenterRenderer.render(
            bundle: bundleWith(presenters: [p]), contextName: "AuditQuotingContext",
            adapter: .defaultFor(contextName: "AuditQuotingContext")
        )
        XCTAssertTrue(outputs[0].content.contains("typealias Output = FooDto?"))
    }

    func testHappyPathScalar() throws {
        let p = presenter(kind: .scalar, elementType: "String", isOptional: true)
        let outputs = try PresenterRenderer.render(
            bundle: bundleWith(presenters: [p]), contextName: "AuditQuotingContext",
            adapter: .defaultFor(contextName: "AuditQuotingContext")
        )
        XCTAssertTrue(outputs[0].content.contains("typealias Output = String?"))
    }

    // MARK: - Cross-aggregate routing (Phase 1.k.2: was silent-skip in 1.k; now routes to context Adapter)

    func testCrossAggregateRoutesToContextAdapter() throws {
        let p = presenter(aggregateRef: "<context-level>")
        let outputs = try PresenterRenderer.render(
            bundle: bundleWith(presenters: [p]), contextName: "AuditQuotingContext",
            adapter: .defaultFor(contextName: "AuditQuotingContext")
        )
        XCTAssertEqual(outputs.count, 1, "context-level presenter must emit one read-side AS in Phase 1.k.2")
        XCTAssertEqual(
            outputs[0].path,
            "Sources/AuditQuotingContext/Adapter/GetThings/GetThingsApplicationService.swift",
            "context-level AS must live in context target (Sources/<contextName>/Adapter/), not under any *Aggregate"
        )
        // Phase 1.k.2 audit-driven: TODO Reference path must point to context-level projector dir.
        XCTAssertTrue(
            outputs[0].content.contains("Reference: Sources/AuditQuotingContext/Projector/"),
            "TODO Reference path must reflect context-level projector location"
        )
    }

    func testUnknownAggregateRefSilentSkip() throws {
        let p = presenter(aggregateRef: "Nonexistent")
        let outputs = try PresenterRenderer.render(
            bundle: bundleWith(presenters: [p]), contextName: "AuditQuotingContext",
            adapter: .defaultFor(contextName: "AuditQuotingContext")
        )
        XCTAssertTrue(outputs.isEmpty, "presenter with unknown aggregateRef silently skipped (defensive)")
    }

    // MARK: - Scaffold-once

    func testScaffoldOnceSkipsExisting() throws {
        let existing: Set<String> = [
            "Sources/AuditQuotingAggregate/Adapter/GetThings/GetThingsApplicationService.swift"
        ]
        let outputs = try PresenterRenderer.render(
            bundle: bundleWith(presenters: [presenter()]),
            contextName: "AuditQuotingContext",
            adapter: .defaultFor(contextName: "AuditQuotingContext"),
            existingPaths: existing
        )
        XCTAssertTrue(outputs.isEmpty, "scaffold-once must skip emit when file in existingPaths")
    }

    // MARK: - Empty bundle

    func testEmptyPresentersReturnsEmpty() throws {
        let outputs = try PresenterRenderer.render(
            bundle: bundleWith(presenters: []), contextName: "AuditQuotingContext",
            adapter: .defaultFor(contextName: "AuditQuotingContext")
        )
        XCTAssertTrue(outputs.isEmpty)
    }

    // MARK: - Input field rendering

    func testInputFieldsRendered() throws {
        let p = PresenterSpec(
            presenterSpecId: "p", name: "GetX",
            readModelRef: "GetX", aggregateRef: "AuditQuoting",
            input: PresenterInput(fields: [
                PresenterInputField(name: "id", type: "String", fromPath: "id"),
                PresenterInputField(name: "filter", type: "String?", fromPath: "filter"),
            ]),
            output: PresenterOutput(kind: .array, elementType: "T", elementSource: "items", isOptional: false),
            endpoint: PresenterEndpoint(path: "/x", method: "GET"),
            comment: nil
        )
        let outputs = try PresenterRenderer.render(
            bundle: FullBundle(manifestVersion: 1, bundleId: "t", context: "AuditQuotingContext",
                              aggregates: [minimalAggregate()], useCases: [], dtos: [], readModels: [], presenters: [p]),
            contextName: "AuditQuotingContext",
            adapter: .defaultFor(contextName: "AuditQuotingContext")
        )
        let c = outputs[0].content
        XCTAssertTrue(c.contains("package let id: String"))
        XCTAssertTrue(c.contains("package let filter: String?"))
        XCTAssertTrue(c.contains("id: String, filter: String?"))
    }
}
