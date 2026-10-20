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

    // MARK: - Phase 1.l.1 — Cosmogony ReadModel schema adapter

    /// Aggregate with `fooCreated` event declared — needed by links derive cross-ref.
    private static let aggregateWithEvent = """
    "aggregates": [{
        "aggregateSpecId": "agg-1",
        "aggregate": "Foo",
        "identity": {"name": "fooId"},
        "state": [],
        "invariants": [],
        "events": [{"name": "fooCreated"}]
    }]
    """

    func testReadModelQueryNameAlias() throws {
        // Cosmogony uses `queryName` (lowerCamelCase) as domain-specific name field.
        // BundleParser should accept it as alias for `name`, normalizing first char to upper
        // (Genesis downstream treats name as Swift type prefix → must be UpperCamelCase).
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateWithEvent),
          "readModels": [{"queryName": "getFoo"}]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.readModels.count, 1)
        XCTAssertEqual(bundle.readModels[0].name, "GetFoo",
            "queryName should be normalized to UpperCamelCase (lowerCamelCase 'getFoo' → 'GetFoo')")
    }

    func testReadModelMissingBothNameAndQueryNameRejected() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateWithEvent),
          "readModels": [{"comment": "no name no queryName"}]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("queryName") || reason.contains("Cosmogony"),
                "error should mention queryName alias hint; got: \(reason)")
        }
    }

    func testReadModelLinksToEventsDerive() throws {
        // Cosmogony emits links[] (generic), Genesis derives events[] (projection view).
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateWithEvent),
          "readModels": [{
            "queryName": "getFoo",
            "links": [
              {"direction": "outbound", "targetType": "DomainEvent", "targetName": "fooCreated"},
              {"direction": "outbound", "targetType": "Aggregate", "targetName": "Foo"}
            ]
          }]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.readModels[0].eventNames, ["fooCreated"],
            "derive only outbound DomainEvent, ignore Aggregate target")
    }

    func testReadModelLinksUnknownEventRejected() throws {
        // links references a DomainEvent that no aggregate declares → bundleInvalid
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateWithEvent),
          "readModels": [{
            "queryName": "getFoo",
            "links": [
              {"direction": "outbound", "targetType": "DomainEvent", "targetName": "phantomEvent"}
            ]
          }]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("phantomEvent"),
                "error should name the unknown event; got: \(reason)")
            XCTAssertTrue(reason.contains("no aggregate"),
                "error should explain the cross-ref miss; got: \(reason)")
        }
    }

    func testReadModelParametersToKeyDerive() throws {
        // Cosmogony emits parameters[] (API contract), Genesis derives key (projection index).
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateWithEvent),
          "readModels": [{
            "queryName": "getFoo",
            "parameters": [
              {"name": "fooId", "type": "String"},
              {"name": "ignored", "type": "Int"}
            ]
          }]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        guard let key = bundle.readModels[0].key else {
            return XCTFail("key should be derived from parameters[0]")
        }
        XCTAssertEqual(key.field, "fooId")
        XCTAssertEqual(key.type, "String")
        XCTAssertEqual(key.fromEventPayload, "fooId",
            "derive assumes parameter name == event payload field name")
    }

    func testReadModelReturnTypeFlatten() throws {
        // Cosmogony emits returnType.fields[] (nested object), Genesis flattens to storedFields[].
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateWithEvent),
          "readModels": [{
            "queryName": "getFoo",
            "returnType": {
              "shape": "object",
              "fields": [
                {"name": "message", "type": "String"},
                {"name": "count", "type": "Int", "dtoSpecRef": "ignored"}
              ]
            }
          }]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        let sf = bundle.readModels[0].storedFields
        XCTAssertEqual(sf.count, 2)
        XCTAssertEqual(sf[0].name, "message")
        XCTAssertEqual(sf[0].type, "String")
        XCTAssertEqual(sf[1].name, "count")
        XCTAssertEqual(sf[1].type, "Int")
    }

    func testReadModelReturnTypeCollectionFieldStaysNonOptional() throws {
        // #29: canvas `Array[String]` return field must NOT be wrapped in Optional — otherwise the read model
        // property is `[String]?` while a presenter array Output is `[String]` and `return readModel.<f>` fails to compile.
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateWithEvent),
          "readModels": [{
            "queryName": "getFoo",
            "returnType": {
              "shape": "object",
              "fields": [
                {"name": "permissions", "type": "Array[String]"},
                {"name": "tags", "type": "Set[String]"},
                {"name": "owner", "type": "OwnerDto"}
              ]
            }
          }]
        }
        """)
        let sf = try BundleParser.parseFull(at: url).readModels[0].storedFields
        XCTAssertEqual(sf.map(\.name), ["permissions", "tags", "owner"])
        XCTAssertEqual(sf[0].type, "Array[String]")
        XCTAssertEqual(sf[1].type, "Set[String]")
        XCTAssertEqual(sf[2].type, "OwnerDto?", "custom (DTO) types keep the Optional wrap")
    }

    func testReadModelExplicitFieldsPreferredOverDerive() throws {
        // Backward compat: when both legacy explicit fields AND Cosmogony derive fields present,
        // explicit wins (no double-emit, no surprise overwrites).
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateWithEvent),
          "readModels": [{
            "name": "explicitName",
            "queryName": "shouldBeIgnored",
            "events": [{"name": "fooCreated", "sourceAggregate": "Foo"}],
            "links": [{"direction": "outbound", "targetType": "DomainEvent", "targetName": "phantomEvent"}],
            "key": {"field": "explicitKey", "type": "String", "fromEventPayload": "explicitKey"},
            "parameters": [{"name": "shouldBeIgnored", "type": "Int"}],
            "storedFields": [{"name": "explicitField", "type": "String"}],
            "returnType": {"shape": "object", "fields": [{"name": "ignored", "type": "Int"}]}
          }]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.readModels[0].name, "explicitName",
            "explicit name wins over queryName")
        XCTAssertEqual(bundle.readModels[0].eventNames, ["fooCreated"],
            "explicit events wins over links derive (no phantomEvent cross-ref error)")
        XCTAssertEqual(bundle.readModels[0].key?.field, "explicitKey",
            "explicit key wins over parameters derive")
        XCTAssertEqual(bundle.readModels[0].storedFields.map(\.name), ["explicitField"],
            "explicit storedFields wins over returnType flatten")
    }

    // MARK: - Phase 1.p — DTO scope/usage validation (D5 reserved-name / D9+D19 forbidden / D20 strict gate)

    private static func dtoEnvelope(manifestVersion: Int = 1) -> String {
        """
        "manifestVersion": \(manifestVersion),
        "bundleId": "abc",
        "context": "FooContext",
        \(Self.aggregateOnly)
        """
    }

    func testDtoReservedNameApiErrorSuffixRejected() throws {
        let url = try writeFixture("""
        {
          \(Self.dtoEnvelope()),
          "dtos": [{
            "dtoSpecId": "d-1",
            "name": "UserAccessProfileApiError"
          }]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("reserved infra pattern"),
                "error should mention reserved-name filter; got: \(reason)")
        }
    }

    func testDtoReservedNamePlusDomainSuffixRejected() throws {
        let url = try writeFixture("""
        {
          \(Self.dtoEnvelope()),
          "dtos": [{
            "dtoSpecId": "d-1",
            "name": "Foo+Domain"
          }]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("+Domain"), "error should name the suffix pattern; got: \(reason)")
        }
    }

    func testDtoPerUseCaseResponseForbidden() throws {
        let url = try writeFixture("""
        {
          \(Self.dtoEnvelope()),
          "dtos": [{
            "dtoSpecId": "d-1",
            "name": "FooDto",
            "scope": "perUseCase",
            "usage": "response",
            "useCaseRef": "createFoo"
          }]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("perUseCase × response"), "error should name the forbidden combo; got: \(reason)")
        }
    }

    func testDtoPerReadModelRequestForbidden() throws {
        let url = try writeFixture("""
        {
          \(Self.dtoEnvelope()),
          "dtos": [{
            "dtoSpecId": "d-1",
            "name": "FooDto",
            "scope": "perReadModel",
            "usage": "request",
            "readModelRef": "getFoo"
          }]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("perReadModel × request"), "error should name the forbidden combo; got: \(reason)")
        }
    }

    func testDtoContextSharedRequestForbidden() throws {
        let url = try writeFixture("""
        {
          \(Self.dtoEnvelope()),
          "dtos": [{
            "dtoSpecId": "d-1",
            "name": "FooDto",
            "scope": "contextShared",
            "usage": "request"
          }]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("contextShared × request"), "error should name the forbidden combo; got: \(reason)")
        }
    }

    func testDtoStrictGateRaisesOnMissingScope() throws {
        // manifestVersion: 2 → strict path; missing scope must raise
        let url = try writeFixture("""
        {
          "manifestVersion": 2,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateOnly),
          "dtos": [{
            "dtoSpecId": "d-1",
            "name": "FooDto"
          }]
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseFull(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("manifestVersion: 2") || reason.contains("strict path"),
                "error should mention manifestVersion strict path; got: \(reason)")
        }
    }

    func testDtoStrictGateAcceptsExplicitScope() throws {
        // manifestVersion: 2 + explicit scope → pass
        let url = try writeFixture("""
        {
          "manifestVersion": 2,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateOnly),
          "dtos": [{
            "dtoSpecId": "d-1",
            "name": "FooDto",
            "scope": "contextShared",
            "usage": "response"
          }]
        }
        """)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.dtos.count, 1)
        XCTAssertEqual(bundle.dtos[0].scope, "contextShared")
    }

    // D20-correction (2026-06-01): manifestVersion>=2 strict gate enforces ONLY dtos[].scope.
    // usage stays optional (D14 default both) — pin that v2 does NOT require usage.
    func testDtoStrictGateDoesNotRequireUsage() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 2,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateOnly),
          "dtos": [{
            "dtoSpecId": "d-1",
            "name": "FooDto",
            "scope": "contextShared"
          }]
        }
        """)
        // scope present, usage absent → must still parse (usage not gated at v2)
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.dtos.count, 1)
        XCTAssertEqual(bundle.dtos[0].scope, "contextShared")
        XCTAssertNil(bundle.dtos[0].usage, "usage stays nil (optional) even under manifestVersion: 2")
    }

    // D20-correction: manifestVersion>=2 does NOT gate ReadModel aggregateRef/key — they derive.
    // A v2 bundle with a readModel lacking explicit aggregateRef/key must still parse via derive.
    func testStrictGateDoesNotForceReadModelAggregateRefOrKey() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 2,
          "bundleId": "abc",
          "context": "FooContext",
          \(Self.aggregateWithEvent),
          "readModels": [{
            "queryName": "getFoo",
            "parameters": [{"name": "fooId", "type": "String"}],
            "links": [
              {"direction": "outbound", "targetType": "DomainEvent", "targetName": "fooCreated"}
            ]
          }]
        }
        """)
        // No explicit aggregateRef / key on the readModel; under v2 these still derive (not gated).
        let bundle = try BundleParser.parseFull(at: url)
        XCTAssertEqual(bundle.readModels.count, 1)
        XCTAssertEqual(bundle.readModels[0].aggregateRef, "Foo", "aggregateRef derived from eventRefs under v2")
        XCTAssertEqual(bundle.readModels[0].key?.field, "fooId", "key derived from parameters[0] under v2")
    }
}
