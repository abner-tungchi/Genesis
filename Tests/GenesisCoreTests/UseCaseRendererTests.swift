import XCTest
@testable import GenesisCore

/// Phase 1.t / D5 + D6: the strict-safe `when(event:)` reducer heuristic and create-UC command skip
/// can't be exercised by the IAM fixture (all non-create UCs are non-strict — Set collections or
/// new*/old* renames — and create is skipped), so they're covered here with synthetic specs.
final class UseCaseRendererTests: XCTestCase {

    private func bundle(aggState: [FieldSpec], useCase: UseCaseSpec) -> FullBundle {
        let agg = AggregateSpec(
            aggregateSpecId: "agg-1",
            name: "Foo",
            identityName: "fooId",
            state: aggState,
            invariants: [],
            eventNames: [useCase.emittedEvent]
        )
        return FullBundle(
            manifestVersion: 1,
            bundleId: "b-1",
            context: "DemoContext",
            aggregates: [agg],
            useCases: [useCase],
            dtos: [],
            readModels: [],
            presenters: []
        )
    }

    private func useCase(_ name: String, event: String, payload: [FieldSpec], input: [FieldSpec]) -> UseCaseSpec {
        UseCaseSpec(
            useCaseSpecId: "uc-1",
            aggregateSpecId: "agg-1",
            useCase: name,
            aggregate: "Foo",
            input: input,
            emittedEvent: event,
            eventPayload: payload,
            preconditions: []
        )
    }

    private func render(_ b: FullBundle) throws -> [(path: String, content: String, role: String)] {
        try UseCaseRenderer.render(
            useCase: b.useCases[0],
            bundle: b,
            adapter: .defaultFor(contextName: "DemoContext")
        )
    }

    private func commandExtension(_ outputs: [(path: String, content: String, role: String)]) -> String? {
        outputs.first { $0.role == "commandExtension" }?.content
    }

    // MARK: - D5 positive: strict-safe scalar → self.<f> = event.<f>

    func testWhenStrictSafeScalarEmitsAssignment() throws {
        let uc = useCase("editBar", event: "barEdited",
                         payload: [FieldSpec(name: "bar", rawType: "String")],
                         input: [FieldSpec(name: "bar", rawType: "String")])
        let b = bundle(aggState: [FieldSpec(name: "bar", rawType: "String")], useCase: uc)
        let cmd = try XCTUnwrap(commandExtension(try render(b)))
        XCTAssertTrue(cmd.contains("self.bar = event.bar"), "strict-safe scalar payload→state should emit assignment; got:\n\(cmd)")
        XCTAssertFalse(cmd.contains("fatalError(\"GENESIS-TODO: implement state transition"), "strict-safe should NOT fatalError")
    }

    // MARK: - D5 negative: collection / type-mismatch / new-old → fatalError obligation

    func testWhenCollectionPayloadEmitsFatalError() throws {
        let uc = useCase("assignTags", event: "tagsAssigned",
                         payload: [FieldSpec(name: "tags", rawType: "Set[String]")],
                         input: [FieldSpec(name: "tags", rawType: "Set[String]")])
        let b = bundle(aggState: [FieldSpec(name: "tags", rawType: "Set[String]")], useCase: uc)
        let cmd = try XCTUnwrap(commandExtension(try render(b)))
        XCTAssertTrue(cmd.contains("fatalError(\"GENESIS-TODO: implement state transition for TagsAssigned\")"),
                      "collection payload is not strict-safe → fatalError; got:\n\(cmd)")
        XCTAssertFalse(cmd.contains("self.tags = event.tags"))
    }

    func testWhenNewOldSemanticRenameEmitsFatalError() throws {
        // payload `newName` does not 1:1-map to state `name` → not strict-safe.
        let uc = useCase("renameFoo", event: "fooRenamed",
                         payload: [FieldSpec(name: "newName", rawType: "String")],
                         input: [FieldSpec(name: "newName", rawType: "String")])
        let b = bundle(aggState: [FieldSpec(name: "name", rawType: "String")], useCase: uc)
        let cmd = try XCTUnwrap(commandExtension(try render(b)))
        XCTAssertTrue(cmd.contains("fatalError(\"GENESIS-TODO: implement state transition for FooRenamed\")"),
                      "new*/old* semantic rename is not strict-safe → fatalError; got:\n\(cmd)")
    }

    // MARK: - D6: create UC emits no command extension

    func testCreateUseCaseSkipsCommandExtension() throws {
        let uc = useCase("createFoo", event: "fooCreated",
                         payload: [FieldSpec(name: "bar", rawType: "String")],
                         input: [FieldSpec(name: "bar", rawType: "String")])
        let b = bundle(aggState: [FieldSpec(name: "bar", rawType: "String")], useCase: uc)
        let outputs = try render(b)
        XCTAssertNil(commandExtension(outputs), "create UC must NOT generate a command extension (D6 dead scaffold)")
        // sanity: it still emits Input/Output/Usecase/Service
        XCTAssertTrue(outputs.contains { $0.role == "service" })
        XCTAssertTrue(outputs.contains { $0.role == "usecase" })
    }
}
