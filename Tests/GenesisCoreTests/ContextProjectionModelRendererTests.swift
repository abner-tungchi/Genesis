import XCTest
@testable import GenesisCore

final class ContextProjectionModelRendererTests: XCTestCase {

    private func twoAggBundle(readModels: [ReadModelSpec] = []) -> FullBundle {
        let aggA = AggregateSpec(
            aggregateSpecId: "agg-a", name: "AuditQuoting",
            identityName: "auditQuotingId", state: [], invariants: [],
            eventNames: ["QuotingProofUploadedToGcs", "AccountingTypeEdited"]
        )
        let aggB = AggregateSpec(
            aggregateSpecId: "agg-b", name: "Permission",
            identityName: "permissionId", state: [], invariants: [],
            eventNames: ["PermissionGranted"]
        )
        return FullBundle(
            manifestVersion: 1, bundleId: "t", context: "AuditQuotingContext",
            aggregates: [aggA, aggB], useCases: [], dtos: [], readModels: readModels
        )
    }

    func testEmptyWhenNoContextLevelReadmodels() throws {
        let bundle = twoAggBundle(readModels: [])
        let outputs = try ContextProjectionModelRenderer.render(bundle: bundle, contextName: "AuditQuotingContext")
        XCTAssertTrue(outputs.isEmpty, "no orphan files emitted when no cross-agg readmodels")
    }

    func testEmitsThreeFilesWhenContextLevelReadmodel() throws {
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: nil,
            name: "GetCrossSummary", eventNames: [],
            aggregateRef: "<context-level>",
            key: ReadModelKey(field: "userId", type: "String", fromEventPayload: "userId"),
            storedFields: [],
            eventRefs: [
                ReadModelEventRef(name: "permissionGranted", sourceAggregate: "Permission"),
                ReadModelEventRef(name: "accountingTypeEdited", sourceAggregate: "AuditQuoting"),
            ],
            comment: nil
        )
        let bundle = twoAggBundle(readModels: [rm])
        let outputs = try ContextProjectionModelRenderer.render(bundle: bundle, contextName: "AuditQuotingContext")
        XCTAssertEqual(outputs.count, 3)
        let paths = Set(outputs.map { $0.path })
        XCTAssertTrue(paths.contains("Sources/AuditQuotingContext/event.yaml"))
        XCTAssertTrue(paths.contains("Sources/AuditQuotingContext/projection-model.yaml"))
        XCTAssertTrue(paths.contains("Sources/AuditQuotingContext/event-generator-config.yaml"))
    }

    func testEventYamlIsEmpty() throws {
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: nil,
            name: "GetX", eventNames: [],
            aggregateRef: "<context-level>",
            key: ReadModelKey(field: "id", type: "String", fromEventPayload: "id"),
            storedFields: [],
            eventRefs: [ReadModelEventRef(name: "fooHappened", sourceAggregate: "AuditQuoting")],
            comment: nil
        )
        let outputs = try ContextProjectionModelRenderer.render(bundle: twoAggBundle(readModels: [rm]), contextName: "X")
        let ev = outputs.first { $0.path.hasSuffix("event.yaml") }!
        XCTAssertEqual(ev.content.trimmingCharacters(in: .whitespacesAndNewlines), "{}")
    }

    func testEventGeneratorConfigDepsSortedAndUnique() throws {
        // Audit M1+M2: deps = unique sourceAggregate set sorted alphabetically
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: nil,
            name: "GetCross", eventNames: [],
            aggregateRef: "<context-level>",
            key: ReadModelKey(field: "userId", type: "String", fromEventPayload: "userId"),
            storedFields: [],
            eventRefs: [
                ReadModelEventRef(name: "permGranted", sourceAggregate: "Permission"),
                ReadModelEventRef(name: "auditEdited", sourceAggregate: "AuditQuoting"),
                ReadModelEventRef(name: "permRevoked", sourceAggregate: "Permission"),  // duplicate source
            ],
            comment: nil
        )
        let outputs = try ContextProjectionModelRenderer.render(bundle: twoAggBundle(readModels: [rm]), contextName: "AuditQuotingContext")
        let cfg = outputs.first { $0.path.hasSuffix("event-generator-config.yaml") }!
        let depLines = cfg.content.components(separatedBy: "\n").filter { $0.hasPrefix("  - ") }
        XCTAssertEqual(depLines, [
            "  - AuditQuotingAggregate",  // sorted
            "  - PermissionAggregate",     // dedupd
            "  - AuditQuotingContextShared",
        ])
    }

    func testProjectionYamlNormalizesEventNames() throws {
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: nil,
            name: "GetCross", eventNames: [],
            aggregateRef: "<context-level>",
            key: ReadModelKey(field: "userId", type: "String", fromEventPayload: "userId"),
            storedFields: [],
            eventRefs: [
                ReadModelEventRef(name: "permissionGranted", sourceAggregate: "Permission"),
                ReadModelEventRef(name: "accountingTypeEdited", sourceAggregate: "AuditQuoting"),
            ],
            comment: nil
        )
        let outputs = try ContextProjectionModelRenderer.render(bundle: twoAggBundle(readModels: [rm]), contextName: "AuditQuotingContext")
        let yaml = outputs.first { $0.path.hasSuffix("projection-model.yaml") }!
        // Per Phase 1.g audit H2: events go UpperCamel uniformly
        XCTAssertTrue(yaml.content.contains("PermissionGranted"))
        XCTAssertTrue(yaml.content.contains("AccountingTypeEdited"))
        XCTAssertFalse(yaml.content.contains("permissionGranted"))
        XCTAssertFalse(yaml.content.contains("accountingTypeEdited"))
    }

    func testHasContextLevelHelper() throws {
        let perAgg = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: "agg-a",
            name: "GetX", eventNames: [],
            aggregateRef: "AuditQuoting",
            key: nil, storedFields: [], eventRefs: [], comment: nil
        )
        XCTAssertFalse(ContextProjectionModelRenderer.hasContextLevel(bundle: twoAggBundle(readModels: [perAgg])))

        let crossAgg = ReadModelSpec(
            readModelSpecId: "rm-2", aggregateSpecId: nil,
            name: "GetY", eventNames: [],
            aggregateRef: "<context-level>",
            key: nil, storedFields: [], eventRefs: [], comment: nil
        )
        XCTAssertTrue(ContextProjectionModelRenderer.hasContextLevel(bundle: twoAggBundle(readModels: [crossAgg])))
    }
}
