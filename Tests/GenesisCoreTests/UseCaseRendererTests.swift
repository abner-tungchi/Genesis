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

    private func usecaseFile(_ outputs: [(path: String, content: String, role: String)]) -> String? {
        outputs.first { $0.role == "usecase" }?.content
    }

    // MARK: - Phase 1.x / D1: codegen emits execute() orchestration body (Create/Update/Delete)

    func testExecuteUpdatePatternEmitsFindCommandSave() throws {
        let uc = useCase("editBar", event: "barEdited",
                         payload: [FieldSpec(name: "bar", rawType: "String")],
                         input: [FieldSpec(name: "bar", rawType: "String")])
        let b = bundle(aggState: [FieldSpec(name: "bar", rawType: "String")], useCase: uc)
        let svc = try XCTUnwrap(usecaseFile(try render(b)))
        XCTAssertFalse(svc.contains("fatalError(\"TODO(/usecase skill)"), "D1: TODO stub must be gone")
        XCTAssertTrue(svc.contains("try await repository.find(byId: input.fooId)"), "Update: find by aggId; got:\n\(svc)")
        XCTAssertTrue(svc.contains("try foo.editBar(bar: input.bar)"), "Update: call command with command args; got:\n\(svc)")
        XCTAssertTrue(svc.contains("try await repository.save(aggregateRoot: foo, userId: input.operatorId)"), "Update: save with operatorId")
    }

    func testExecuteCreatePatternEmitsInit() throws {
        let uc = useCase("createFoo", event: "fooCreated",
                         payload: [FieldSpec(name: "bar", rawType: "String")],
                         input: [FieldSpec(name: "bar", rawType: "String")])
        let b = bundle(aggState: [FieldSpec(name: "bar", rawType: "String")], useCase: uc)
        let svc = try XCTUnwrap(usecaseFile(try render(b)))
        XCTAssertFalse(svc.contains("fatalError(\"TODO(/usecase skill)"), "D1: TODO stub must be gone")
        XCTAssertTrue(svc.contains("try Foo(id: input.fooId, bar: input.bar)"), "Create: construct via init; got:\n\(svc)")
        XCTAssertTrue(svc.contains("return .init(id: input.fooId, message: nil)"), "Create: return caller-provided id")
    }

    func testExecuteDeletePatternEmitsRepositoryDelete() throws {
        let uc = useCase("deleteFoo", event: "fooDeleted",
                         payload: [FieldSpec(name: "bar", rawType: "String")],
                         input: [FieldSpec(name: "bar", rawType: "String")])
        let b = bundle(aggState: [FieldSpec(name: "bar", rawType: "String")], useCase: uc)
        let svc = try XCTUnwrap(usecaseFile(try render(b)))
        XCTAssertTrue(svc.contains("try await repository.delete(byId: foo.id, userId: input.operatorId)"), "Delete: repository.delete; got:\n\(svc)")
        XCTAssertFalse(svc.contains("fatalError(\"TODO(/usecase skill)"), "D1: TODO stub must be gone")
    }

    // MARK: - D5 positive: strict-safe scalar → self.<f> = event.<f>

    func testWhenStrictSafeScalarEmitsAssignment() throws {
        let uc = useCase("editBar", event: "barEdited",
                         payload: [FieldSpec(name: "bar", rawType: "String")],
                         input: [FieldSpec(name: "bar", rawType: "String")])
        let b = bundle(aggState: [FieldSpec(name: "bar", rawType: "String")], useCase: uc)
        let cmd = try XCTUnwrap(commandExtension(try render(b)))
        XCTAssertTrue(cmd.contains("self.bar = event.bar"), "strict-safe scalar payload→state should emit assignment; got:\n\(cmd)")
        XCTAssertFalse(cmd.contains("throw GenesisTODO.notImplemented(\"when"), "strict-safe should NOT throw GenesisTODO")
    }

    // MARK: - C2 negative: collection / type-mismatch / new-old → #error hole (Phase 1.u)

    func testWhenCollectionPayloadEmitsErrorHole() throws {
        let uc = useCase("assignTags", event: "tagsAssigned",
                         payload: [FieldSpec(name: "tags", rawType: "Set[String]")],
                         input: [FieldSpec(name: "tags", rawType: "Set[String]")])
        let b = bundle(aggState: [FieldSpec(name: "tags", rawType: "Set[String]")], useCase: uc)
        let cmd = try XCTUnwrap(commandExtension(try render(b)))
        XCTAssertTrue(cmd.contains("throw GenesisTODO.notImplemented(\"when(TagsAssigned) state transition\")"),
                      "collection payload is not strict-safe → #error; got:\n\(cmd)")
        XCTAssertFalse(cmd.contains("self.tags = event.tags"))
    }

    func testWhenNewOldSemanticRenameEmitsErrorHole() throws {
        // payload `newName` does not 1:1-map to state `name` → not strict-safe.
        let uc = useCase("renameFoo", event: "fooRenamed",
                         payload: [FieldSpec(name: "newName", rawType: "String")],
                         input: [FieldSpec(name: "newName", rawType: "String")])
        let b = bundle(aggState: [FieldSpec(name: "name", rawType: "String")], useCase: uc)
        let cmd = try XCTUnwrap(commandExtension(try render(b)))
        XCTAssertTrue(cmd.contains("throw GenesisTODO.notImplemented(\"when(FooRenamed) state transition\")"),
                      "new*/old* semantic rename is not strict-safe → #error; got:\n\(cmd)")
    }

    // MARK: - C1 + A1: command body precondition scaffold + #error hole (Phase 1.u)

    func testCommandBodyEmitsPreconditionScaffoldAndErrorHole() throws {
        var uc = useCase("editBar", event: "barEdited",
                         payload: [FieldSpec(name: "bar", rawType: "String")],
                         input: [FieldSpec(name: "bar", rawType: "String")])
        uc = UseCaseSpec(useCaseSpecId: uc.useCaseSpecId, aggregateSpecId: uc.aggregateSpecId,
                         useCase: uc.useCase, aggregate: uc.aggregate, input: uc.input,
                         emittedEvent: uc.emittedEvent, eventPayload: uc.eventPayload,
                         preconditions: ["bar must be non-empty"])
        let b = bundle(aggState: [FieldSpec(name: "bar", rawType: "String")], useCase: uc)
        let cmd = try XCTUnwrap(commandExtension(try render(b)))
        XCTAssertTrue(cmd.contains("// PRECONDITION (from bundle): bar must be non-empty"),
                      "command body should carry bundle precondition as comment; got:\n\(cmd)")
        XCTAssertTrue(cmd.contains("throw GenesisTODO.notImplemented(\"editBar"),
                      "command body should throw GenesisTODO hole; got:\n\(cmd)")
        XCTAssertFalse(cmd.contains("fatalError(\"not implemented\")"), "legacy fatalError must be gone")
    }

    func testCommandBodyNoPreconditionsShowsNoneDeclared() throws {
        // useCase(...) helper sets preconditions: [] → scaffold should say "none declared"
        let uc = useCase("editBar", event: "barEdited",
                         payload: [FieldSpec(name: "bar", rawType: "String")],
                         input: [FieldSpec(name: "bar", rawType: "String")])
        let b = bundle(aggState: [FieldSpec(name: "bar", rawType: "String")], useCase: uc)
        let cmd = try XCTUnwrap(commandExtension(try render(b)))
        XCTAssertTrue(cmd.contains("// PRECONDITION (from bundle): none declared."),
                      "no preconditions → 'none declared'; got:\n\(cmd)")
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
