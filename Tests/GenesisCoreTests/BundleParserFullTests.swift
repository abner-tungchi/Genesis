import XCTest
@testable import GenesisCore

final class BundleParserFullTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleParserFullTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFixture(_ json: String) throws -> URL {
        let url = tmpDir.appendingPathComponent("bundle.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParseHappyPath() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          "aggregates": [{
            "aggregateSpecId": "agg-1",
            "aggregate": "Foo",
            "identity": {"name": "fooId"},
            "state": [{"name": "bar", "type": "String"}],
            "invariants": [{
              "id": "inv-1",
              "name": "checkBar",
              "title": "Bar must exist",
              "errorCode": "barMissing",
              "rules": [{"when": "always", "rule": "bar != null"}],
              "status": "confirmed"
            }],
            "events": [{"name": "fooCreated"}]
          }],
          "useCases": [{
            "useCaseSpecId": "uc-1",
            "aggregateSpecId": "agg-1",
            "useCase": "createFoo",
            "aggregate": "Foo",
            "input": [{"name": "bar", "type": "String"}],
            "emittedEvent": "fooCreated",
            "eventPayload": [{"name": "bar", "type": "String"}],
            "preconditions": []
          }],
          "readModels": [],
          "dtos": []
        }
        """)

        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.context, "FooContext")
        XCTAssertEqual(bundle.aggregates.count, 1)
        XCTAssertEqual(bundle.aggregates[0].name, "Foo")
        XCTAssertEqual(bundle.aggregates[0].state.first?.name, "bar")
        XCTAssertEqual(bundle.useCases.count, 1)
        XCTAssertEqual(bundle.useCases[0].emittedEvent, "fooCreated")
    }

    func testParseFromRealIAMBundle() throws {
        guard let fixture = Bundle.module.url(forResource: "iam-bundle", withExtension: "json", subdirectory: "Fixtures") else {
            // GenesisCoreTests doesn't bundle Fixtures; load via the integration tests path instead.
            let alt = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("GenesisIntegrationTests/Fixtures/iam-bundle.json")
            let bundle = try BundleParser.parseFull(at: alt)
            XCTAssertEqual(bundle.context, "IAMContext")
            XCTAssertEqual(bundle.aggregates.count, 1)
            XCTAssertEqual(bundle.aggregates[0].name, "UserAccessProfile")
            XCTAssertEqual(bundle.useCases.count, 7)
            XCTAssertEqual(bundle.dtos.count, 1)
            XCTAssertEqual(bundle.dtos[0].name, "EmployeeStatus")
            return
        }
        let bundle = try BundleParser.parseFull(at: fixture)
        XCTAssertEqual(bundle.context, "IAMContext")
    }

    func testNoAggregatesRejected() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          "aggregates": []
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("no aggregates"))
        }
    }

    // MARK: - Phase 1.e: readModels parsing (no longer rejected)

    private static let aggregateOnly = """
    "aggregates": [{
        "aggregateSpecId": "agg-1",
        "aggregate": "Foo",
        "identity": {"name": "fooId"},
        "state": [],
        "invariants": [],
        "events": []
    }]
    """

    func testReadModelsEmptyReturnsEmpty() throws {
        // Phase 1.b's "readModels not supported" reject is gone. Empty array now accepted.
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateOnly),
          "readModels": []
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertTrue(bundle.readModels.isEmpty)
    }

    func testReadModelMissingNameRejected() throws {
        // Phase 2 (/readmodel skill): readModelSpecId is now optional (auto-derived
        // from name). Only `name` remains required for a readModel entry.
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateOnly),
          "readModels": [{}]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("name"), "reason: \(reason)")
        }
    }

    func testReadModelMinimalNameOnlyAccepted() throws {
        // Phase 2 (/readmodel skill): minimal readModel `{name: "X"}` is now valid.
        // Legacy strict-schema rejection (Phase 1.e) was loosened to support the
        // schema-migration use case where the /readmodel skill builds up entries
        // incrementally.
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateOnly),
          "readModels": [{"name": "FooReadModel"}]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.readModels.count, 1)
        XCTAssertEqual(bundle.readModels[0].name, "FooReadModel")
        XCTAssertEqual(bundle.readModels[0].readModelSpecId, "rm-FooReadModel",
            "readModelSpecId auto-derived from name when missing")
        XCTAssertTrue(bundle.readModels[0].eventNames.isEmpty)
        XCTAssertNil(bundle.readModels[0].key)
        XCTAssertNil(bundle.readModels[0].aggregateRef)
    }

    func testReadModelEventsAsObjectsParsed() throws {
        // Cosmogony shape: events as [{name: String}]
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateOnly),
          "readModels": [
            {
              "readModelSpecId": "rm-1",
              "aggregateSpecId": "agg-1",
              "name": "GetFooSnapshot",
              "events": [{"name": "FooCreated"}, {"name": "FooEdited"}]
            }
          ]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.readModels.count, 1)
        XCTAssertEqual(bundle.readModels[0].readModelSpecId, "rm-1")
        XCTAssertEqual(bundle.readModels[0].aggregateSpecId, "agg-1")
        XCTAssertEqual(bundle.readModels[0].name, "GetFooSnapshot")
        XCTAssertEqual(bundle.readModels[0].eventNames, ["FooCreated", "FooEdited"])
    }

    func testReadModelEventsAsStringsParsed() throws {
        // Alt shape: events as flat [String]
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateOnly),
          "readModels": [
            {
              "readModelSpecId": "rm-1",
              "name": "GetX",
              "events": ["EventA", "EventB"]
            }
          ]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.readModels[0].eventNames, ["EventA", "EventB"])
    }

    func testReadModelEventNamesFallbackParsed() throws {
        // Alt shape: eventNames key
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateOnly),
          "readModels": [
            {
              "readModelSpecId": "rm-1",
              "name": "GetY",
              "eventNames": ["EventA"]
            }
          ]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.readModels[0].eventNames, ["EventA"])
    }

    func testReadModelAggregateSpecIdOptional() throws {
        // No aggregateSpecId → nil (context-level readModel)
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateOnly),
          "readModels": [
            {
              "readModelSpecId": "rm-ctx",
              "name": "GetCtx",
              "events": []
            }
          ]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertNil(bundle.readModels[0].aggregateSpecId)
    }

    func testUseCaseReferencesUnknownAggregate() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          "aggregates": [{
            "aggregateSpecId": "agg-1",
            "aggregate": "Foo",
            "identity": {"name": "fooId"},
            "state": [],
            "invariants": [],
            "events": [{"name": "fooCreated"}]
          }],
          "useCases": [{
            "useCaseSpecId": "uc-1",
            "aggregateSpecId": "agg-MISSING",
            "useCase": "x",
            "aggregate": "Foo",
            "input": [],
            "emittedEvent": "fooCreated",
            "eventPayload": [],
            "preconditions": []
          }]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("unknown aggregateSpecId"))
        }
    }

    func testUseCaseEmittedEventNotInAggregate() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          "aggregates": [{
            "aggregateSpecId": "agg-1",
            "aggregate": "Foo",
            "identity": {"name": "fooId"},
            "state": [],
            "invariants": [],
            "events": [{"name": "fooCreated"}]
          }],
          "useCases": [{
            "useCaseSpecId": "uc-1",
            "aggregateSpecId": "agg-1",
            "useCase": "x",
            "aggregate": "Foo",
            "input": [],
            "emittedEvent": "nonexistentEvent",
            "eventPayload": [],
            "preconditions": []
          }]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("nonexistentEvent"))
        }
    }

    func testParseMinimalStillWorksUnchanged() throws {
        let url = try writeFixture("""
        {"manifestVersion": 1, "bundleId": "x", "context": "Y"}
        """)
        let mb = try BundleParser.parseMinimal(at: url)
        XCTAssertEqual(mb.context, "Y")
    }
}
