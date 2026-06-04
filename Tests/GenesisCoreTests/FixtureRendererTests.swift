import XCTest
@testable import GenesisCore

/// Golden-file tests for FixtureRenderer: bare UsecaseCall wrappers are signature-derived, so they are
/// CI-locked here (the whole point of codegen-over-skill). Covers create/update/delete uniformity,
/// multi-aggregate file split, ucCamel naming, header signpost + no-defaults, read-side exclusion, and the
/// drift gate (#7): the fixture's `.init(...)` arg order must match the REAL `<UC>Input.init` by construction.
final class FixtureRendererTests: XCTestCase {

    // MARK: - builders (mirror UseCaseRendererTests)

    private func useCase(_ name: String, aggSpecId: String = "agg-1", aggName: String = "Foo", input: [FieldSpec]) -> UseCaseSpec {
        UseCaseSpec(
            useCaseSpecId: "uc-\(name)",
            aggregateSpecId: aggSpecId,
            useCase: name,
            aggregate: aggName,
            input: input,
            emittedEvent: "\(name)Happened",
            eventPayload: [],
            preconditions: []
        )
    }

    private func aggregate(_ name: String = "Foo", id: String = "agg-1", identity: String = "fooId", events: [String] = []) -> AggregateSpec {
        AggregateSpec(aggregateSpecId: id, name: name, identityName: identity, state: [], invariants: [], eventNames: events)
    }

    private func bundle(useCases: [UseCaseSpec], aggregates: [AggregateSpec]? = nil) -> FullBundle {
        let aggs = aggregates ?? [aggregate(events: useCases.map { $0.emittedEvent })]
        return FullBundle(
            manifestVersion: 1, bundleId: "b-1", context: "DemoContext",
            aggregates: aggs, useCases: useCases, dtos: [], readModels: [], presenters: []
        )
    }

    private func render(_ b: FullBundle) throws -> [(path: String, content: String, role: String)] {
        try FixtureRenderer.render(bundle: b, adapter: .defaultFor(contextName: b.context), contextName: b.context)
    }

    private func renderOneFile(_ b: FullBundle) throws -> String {
        try XCTUnwrap(render(b).first?.content)
    }

    /// labels inside the first `(...)` following `marker` (naive first-`)` close — fine for nominal types).
    private func labelsAfter(_ marker: String, in s: String) -> [String] {
        guard let r = s.range(of: marker), let close = s[r.upperBound...].firstIndex(of: ")") else { return [] }
        let inner = s[r.upperBound..<close]
        return inner.split(separator: ",").map {
            String($0.split(separator: ":").first ?? "").trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - shapes (create / update / delete uniform)

    func testCreateFixtureShape() throws {
        let fx = try renderOneFile(bundle(useCases: [useCase("createFoo", input: [FieldSpec(name: "bar", rawType: "String")])]))
        XCTAssertTrue(fx.contains("@discardableResult"))
        XCTAssertTrue(fx.contains("func createFoo(fooId: String, bar: String, operatorId: String, repository: FooRepository) async throws -> String?"), fx)
        XCTAssertTrue(fx.contains("let output = try await CreateFooService(repository: repository).execute(input: .init(fooId: fooId, bar: bar, operatorId: operatorId))"), fx)
        XCTAssertTrue(fx.contains("return output.id"))
        XCTAssertTrue(fx.contains("import FooAggregate"))
        XCTAssertTrue(fx.contains("import Foundation"))
    }

    func testUpdateFixtureShape() throws {
        let fx = try renderOneFile(bundle(useCases: [useCase("editBar", input: [FieldSpec(name: "bar", rawType: "String")])]))
        XCTAssertTrue(fx.contains("func editBar(fooId: String, bar: String, operatorId: String, repository: FooRepository) async throws -> String?"), fx)
        XCTAssertTrue(fx.contains("EditBarService(repository: repository).execute(input: .init(fooId: fooId, bar: bar, operatorId: operatorId))"), fx)
    }

    func testDeleteFixtureIsUniform() throws {
        // delete UC: no business fields → just aggId + operatorId; same one-liner shape as create/update.
        let fx = try renderOneFile(bundle(useCases: [useCase("deleteFoo", input: [])]))
        XCTAssertTrue(fx.contains("func deleteFoo(fooId: String, operatorId: String, repository: FooRepository) async throws -> String?"), fx)
        XCTAssertTrue(fx.contains("DeleteFooService(repository: repository).execute(input: .init(fooId: fooId, operatorId: operatorId))"), fx)
        XCTAssertFalse(fx.contains("repository.find"), "fixture must NOT reimplement execute's dispatch — uniform .execute call only")
    }

    func testNameIsUcCamelMultiWord() throws {
        let fx = try renderOneFile(bundle(useCases: [useCase("promoteUser", input: [FieldSpec(name: "newJobTitle", rawType: "String")])]))
        XCTAssertTrue(fx.contains("func promoteUser(fooId: String, newJobTitle: String, operatorId: String, repository: FooRepository)"), fx)
        XCTAssertTrue(fx.contains("PromoteUserService(repository: repository)"), fx)
    }

    // MARK: - file split / location

    func testMultiAggregateSeparateFiles() throws {
        let ucA = useCase("editBar", aggSpecId: "agg-A", aggName: "Foo", input: [FieldSpec(name: "bar", rawType: "String")])
        let ucB = useCase("editBaz", aggSpecId: "agg-B", aggName: "Bar", input: [FieldSpec(name: "baz", rawType: "String")])
        let aggA = aggregate("Foo", id: "agg-A", identity: "fooId", events: [ucA.emittedEvent])
        let aggB = aggregate("Bar", id: "agg-B", identity: "barId", events: [ucB.emittedEvent])
        let outs = try render(bundle(useCases: [ucA, ucB], aggregates: [aggA, aggB]))
        XCTAssertEqual(outs.count, 2)
        let foo = try XCTUnwrap(outs.first { $0.path == "Tests/DemoContextTests/SharedUtility/UsecaseCall/Foo.swift" })
        let bar = try XCTUnwrap(outs.first { $0.path == "Tests/DemoContextTests/SharedUtility/UsecaseCall/Bar.swift" })
        XCTAssertEqual(foo.role, "fixture")
        XCTAssertTrue(foo.content.contains("import FooAggregate") && foo.content.contains("func editBar("))
        XCTAssertFalse(foo.content.contains("import BarAggregate"), "no cross-aggregate import")
        XCTAssertTrue(bar.content.contains("import BarAggregate") && bar.content.contains("func editBaz(") && bar.content.contains("barId: String"))
    }

    // MARK: - header signpost + no defaults

    func testHeaderSignpostAndNoParameterDefaults() throws {
        let fx = try renderOneFile(bundle(useCases: [useCase("editBar", input: [FieldSpec(name: "bar", rawType: "String")])]))
        XCTAssertTrue(fx.contains("regenerated wholesale"), "header signpost present")
        XCTAssertTrue(fx.contains("Fixtures.presets.swift"), "header points to the human-owned preset sibling")
        // No parameter default on the bare wrapper — strip // comment lines (the header's `= .established`
        // example would false-match), then assert no `= .value` default remains.
        let nonComment = fx.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertNil(nonComment.range(of: #"=\s*\.[A-Za-z]"#, options: .regularExpression),
                     "bare wrapper must have ZERO parameter defaults (D3)")
    }

    // MARK: - drift gate (#7): .init args == <UC>Input.init params, by construction

    func testInitArgsMatchUsecaseInputByConstruction() throws {
        let uc = useCase("editBar", input: [FieldSpec(name: "bar", rawType: "String"), FieldSpec(name: "baz", rawType: "Int")])
        let b = bundle(useCases: [uc])
        // fixture .init(...) arg labels (from the execute call)
        let fx = try renderOneFile(b)
        let fixtureArgs = labelsAfter(".init(", in: fx)
        // REAL <UC>Input.init param labels (run the actual UseCaseRenderer, do NOT hand-write the expectation)
        let ucOut = try UseCaseRenderer.render(useCase: uc, bundle: b, adapter: .defaultFor(contextName: b.context))
        let inputFile = try XCTUnwrap(ucOut.first { $0.role == "usecaseInput" }?.content)
        let inputParams = labelsAfter("package init(", in: inputFile)
        XCTAssertEqual(fixtureArgs, inputParams,
                       "fixture .init args must match <UC>Input.init param ORDER by construction (drift gate)")
        XCTAssertEqual(fixtureArgs, ["fooId", "bar", "baz", "operatorId"])
    }

    // MARK: - read-side exclusion

    func testAggregateWithNoUseCasesGetsNoFixtureFile() throws {
        let agg = aggregate("Foo", id: "agg-1", identity: "fooId", events: [])
        let b = FullBundle(
            manifestVersion: 1, bundleId: "b-1", context: "DemoContext",
            aggregates: [agg], useCases: [], dtos: [], readModels: [], presenters: []
        )
        let outs = try render(b)
        XCTAssertTrue(outs.isEmpty, "an aggregate with no useCases (read-side only) gets no fixture file")
    }
}
