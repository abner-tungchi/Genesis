import XCTest
@testable import GenesisCore

final class ProjectionModelRendererTests: XCTestCase {
    private func render(
        aggregateName: String = "UserAccessProfile",
        aggregateSpecId: String = "agg-1",
        aggregateEventNames: Set<String> = ["UserAccessProfileCreated", "PrivilegeGranted", "UserAccessProfileDeleted"],
        createdEventTypeName: String = "UserAccessProfileCreated",
        readModels: [ReadModelSpec] = []
    ) throws -> (path: String, content: String, role: String) {
        try ProjectionModelRenderer.render(
            aggregateName: aggregateName,
            aggregateSpecId: aggregateSpecId,
            aggregateEventNames: aggregateEventNames,
            createdEventTypeName: createdEventTypeName,
            readModels: readModels
        )
    }

    func testRenderPathIsExpected() throws {
        let out = try render()
        XCTAssertEqual(out.path, "Sources/UserAccessProfileAggregate/projection-model.yaml")
        XCTAssertEqual(out.role, "projectionModel")
    }

    func testRenderEmptyReadModelsEmitsFallback() throws {
        let out = try render(readModels: [])
        XCTAssertTrue(out.content.contains("GetUserAccessProfileExistence:"))
        XCTAssertTrue(out.content.contains("model: readModel"))
        XCTAssertTrue(out.content.contains("    - UserAccessProfileCreated"))
    }

    func testRenderNonEmptyReadModelsScopedToAggregate() throws {
        // Three readModels: 2 target this aggregate, 1 targets a different aggregate.
        // Output should contain the 2 matching entries and exclude the one for the other aggregate.
        let rms = [
            ReadModelSpec(readModelSpecId: "rm-1", aggregateSpecId: "agg-1", name: "GetPrivileges", eventNames: ["PrivilegeGranted"]),
            ReadModelSpec(readModelSpecId: "rm-2", aggregateSpecId: "agg-1", name: "GetExistence", eventNames: ["UserAccessProfileCreated"]),
            ReadModelSpec(readModelSpecId: "rm-3", aggregateSpecId: "other-agg", name: "GetOther", eventNames: ["SomeOtherEvent"]),
        ]
        let out = try render(readModels: rms)
        XCTAssertTrue(out.content.contains("GetPrivileges:"))
        XCTAssertTrue(out.content.contains("GetExistence:"))
        XCTAssertFalse(out.content.contains("GetOther:"), "readModel for other aggregate must be filtered out")
    }

    func testRenderContextLevelReadModelIncludedInAllAggregates() throws {
        // aggregateSpecId == nil means context-level (opt-in for every aggregate).
        let rms = [
            ReadModelSpec(readModelSpecId: "rm-ctx", aggregateSpecId: nil, name: "GetCounter", eventNames: ["UserAccessProfileCreated"]),
        ]
        let outA = try render(aggregateSpecId: "agg-1", readModels: rms)
        let outB = try render(aggregateName: "OtherAgg", aggregateSpecId: "agg-2", aggregateEventNames: ["UserAccessProfileCreated"], readModels: rms)
        XCTAssertTrue(outA.content.contains("GetCounter:"))
        XCTAssertTrue(outB.content.contains("GetCounter:"))
    }

    func testRenderFiltersUnknownEvents() throws {
        // readModel references both known + unknown events. Unknown ones are filtered out.
        let rms = [
            ReadModelSpec(
                readModelSpecId: "rm-1",
                aggregateSpecId: "agg-1",
                name: "GetMixed",
                eventNames: ["PrivilegeGranted", "EventFromAnotherAggregate", "UserAccessProfileCreated"]
            ),
        ]
        let out = try render(readModels: rms)
        XCTAssertTrue(out.content.contains("GetMixed:"))
        XCTAssertTrue(out.content.contains("    - PrivilegeGranted"))
        XCTAssertTrue(out.content.contains("    - UserAccessProfileCreated"))
        XCTAssertFalse(out.content.contains("EventFromAnotherAggregate"), "unknown events must be filtered")
    }

    func testRenderDropsEntryAfterFilteringAllEvents() throws {
        // If all of a readModel's events are unknown to this aggregate, drop the entry entirely.
        // With 0 surviving entries, fallback fires.
        let rms = [
            ReadModelSpec(readModelSpecId: "rm-1", aggregateSpecId: "agg-1", name: "GetAllUnknown", eventNames: ["EventA", "EventB"]),
        ]
        let out = try render(readModels: rms)
        XCTAssertFalse(out.content.contains("GetAllUnknown:"), "entry with no matching events must be dropped")
        XCTAssertTrue(out.content.contains("GetUserAccessProfileExistence:"), "fallback fires when scoped set is empty")
    }

    func testEventListIndentation() throws {
        let rms = [
            ReadModelSpec(readModelSpecId: "rm-1", aggregateSpecId: "agg-1", name: "GetX", eventNames: ["PrivilegeGranted"]),
        ]
        let out = try render(readModels: rms)
        // Each event line: 4 spaces + dash + space + name (yaml `events:` list at depth 2)
        XCTAssertTrue(out.content.contains("\n    - PrivilegeGranted"))
    }
}
