import XCTest
@testable import GenesisCore

final class ReadModelRendererTests: XCTestCase {

    // MARK: - Fixtures

    private func minimalAggregate(
        name: String = "AuditQuoting",
        events: [String] = ["QuotingProofUploadedToGcs", "QuotingProofOnGcsRemoved"]
    ) -> AggregateSpec {
        AggregateSpec(
            aggregateSpecId: "agg-\(name)",
            name: name,
            identityName: "\(name.prefix(1).lowercased())\(name.dropFirst())Id",
            state: [],
            invariants: [],
            eventNames: events
        )
    }

    private func minimalBundle(
        contextName: String = "AuditQuotingContext",
        readModels: [ReadModelSpec] = []
    ) -> FullBundle {
        FullBundle(
            manifestVersion: 1,
            bundleId: "test",
            context: contextName,
            aggregates: [minimalAggregate()],
            useCases: [],
            dtos: [],
            readModels: readModels
        )
    }

    private func defaultAdapter() -> Adapter {
        .defaultFor(contextName: "AuditQuotingContext")
    }

    private func happyReadModel(
        name: String = "GetQuotingProofs",
        aggregateRef: String = "AuditQuoting",
        events: [String] = ["QuotingProofUploadedToGcs", "QuotingProofOnGcsRemoved"]
    ) -> ReadModelSpec {
        ReadModelSpec(
            readModelSpecId: "rm-\(name)",
            aggregateSpecId: "agg-\(aggregateRef)",
            name: name,
            eventNames: events,
            aggregateRef: aggregateRef,
            key: ReadModelKey(field: "auditQuotingId", type: "String", fromEventPayload: "quotingId"),
            storedFields: [
                ReadModelStoredField(name: "documentId", type: "String?", defaultValue: nil)
            ],
            eventRefs: events.map { ReadModelEventRef(name: $0, sourceAggregate: aggregateRef) },
            comment: nil
        )
    }

    // MARK: - Happy path

    func testHappyPathPerAggregateOutputs() throws {
        let bundle = minimalBundle(readModels: [happyReadModel()])
        let outputs = try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )
        XCTAssertEqual(outputs.count, 3)
        let paths = Set(outputs.map { $0.path })
        XCTAssertTrue(paths.contains("Sources/AuditQuotingAggregate/Usecase/Projector/GetQuotingProofs/QuotingProofsReadModel.swift"))
        XCTAssertTrue(paths.contains("Sources/AuditQuotingAggregate/Usecase/Projector/GetQuotingProofs/GetQuotingProofsPresenter.swift"))
        XCTAssertTrue(paths.contains("projections/AUDIT_QUOTING_GetQuotingProofsProjection.js"))
    }

    func testHappyPathContentSanity() throws {
        let bundle = minimalBundle(readModels: [happyReadModel()])
        let outputs = try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )
        let rm = outputs.first(where: { $0.path.hasSuffix("QuotingProofsReadModel.swift") })!
        XCTAssertTrue(rm.content.contains("package class QuotingProofsReadModel: ReadModel"))
        XCTAssertTrue(rm.content.contains("package var auditQuotingId: String"),
            "ReadModel must declare backing key field (audit H1)")
        XCTAssertTrue(rm.content.contains("package var id: String { auditQuotingId }"))
        XCTAssertTrue(rm.content.contains("import AuditQuotingContextShared"))

        let pr = outputs.first(where: { $0.path.hasSuffix("Presenter.swift") })!
        XCTAssertTrue(pr.content.contains("package struct GetQuotingProofsPresenter: GetQuotingProofsProjectorProtocol"))
        XCTAssertTrue(pr.content.contains("CQRSProjectorInput"))
        XCTAssertTrue(pr.content.contains("KurrentStorageCoordinator"))
        XCTAssertTrue(pr.content.contains("AUDIT_QUOTING_"), "ProjectionStreamPrefix")

        let js = outputs.first(where: { $0.path.hasSuffix("Projection.js") })!
        XCTAssertTrue(js.content.contains("fromStreams([\"$ce-AUDIT_QUOTINGAuditQuoting\"])"),
            "$ce- source streams use SourceCategoryPrefix (no trailing _) — audit M1")
        XCTAssertTrue(js.content.contains("linkTo(\"AUDIT_QUOTING_GetQuotingProofs-\""),
            "linkTo uses ProjectionStreamPrefix (with _) — audit M1")
        XCTAssertTrue(js.content.contains("event.body[\"quotingId\"]"))
    }

    // MARK: - Validation (audit H3/H4)

    func testContextLevelRendersToContextDir() throws {
        // Phase 1.g.2: cross-aggregate readmodels now render to Sources/{Context}/Projector/...
        let secondAgg = AggregateSpec(
            aggregateSpecId: "agg-2", name: "Permission",
            identityName: "permissionId", state: [], invariants: [],
            eventNames: ["PermissionGranted"]
        )
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: nil,
            name: "GetCrossSummary", eventNames: ["FooHappened", "PermissionGranted"],
            aggregateRef: "<context-level>",
            key: ReadModelKey(field: "userId", type: "String", fromEventPayload: "userId"),
            storedFields: [],
            eventRefs: [
                ReadModelEventRef(name: "QuotingProofUploadedToGcs", sourceAggregate: "AuditQuoting"),
                ReadModelEventRef(name: "PermissionGranted", sourceAggregate: "Permission"),
            ],
            comment: nil
        )
        let bundle = FullBundle(
            manifestVersion: 1, bundleId: "t", context: "AuditQuotingContext",
            aggregates: [minimalAggregate(), secondAgg],
            useCases: [], dtos: [], readModels: [rm]
        )
        let outputs = try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )
        let paths = Set(outputs.map { $0.path })
        XCTAssertTrue(paths.contains("Sources/AuditQuotingContext/Projector/GetCrossSummary/CrossSummaryReadModel.swift"))
        XCTAssertTrue(paths.contains("Sources/AuditQuotingContext/Projector/GetCrossSummary/GetCrossSummaryPresenter.swift"))
        // Presenter must have multi-aggregate imports (sorted alphabetical for determinism per audit M2)
        let pr = outputs.first(where: { $0.path.hasSuffix("Presenter.swift") })!
        XCTAssertTrue(pr.content.contains("import AuditQuotingAggregate"))
        XCTAssertTrue(pr.content.contains("import PermissionAggregate"))
        // Sort check: AuditQuoting < Permission alphabetically, so AuditQuotingAggregate should appear first
        if let a = pr.content.range(of: "import AuditQuotingAggregate"),
           let p = pr.content.range(of: "import PermissionAggregate") {
            XCTAssertLessThan(a.lowerBound, p.lowerBound, "imports must be sorted alphabetically")
        }
    }

    func testPerAggregateReadModelHasNoAggregateImports() throws {
        // Audit M3: per-aggregate Presenter must NOT have stray {AggregateImports} placeholder or extra imports
        let bundle = minimalBundle(readModels: [happyReadModel()])
        let outputs = try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )
        let pr = outputs.first(where: { $0.path.hasSuffix("Presenter.swift") })!
        XCTAssertFalse(pr.content.contains("{AggregateImports}"), "placeholder must be substituted")
        XCTAssertFalse(pr.content.contains("import AuditQuotingAggregate"), "per-aggregate readmodel doesn't need self-import")
    }

    func testMissingKeyThrows() throws {
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: "agg-AuditQuoting",
            name: "GetThing", eventNames: ["FooHappened"],
            aggregateRef: "AuditQuoting",
            key: nil,
            storedFields: [],
            eventRefs: [ReadModelEventRef(name: "FooHappened", sourceAggregate: "AuditQuoting")],
            comment: nil
        )
        let bundle = FullBundle(
            manifestVersion: 1, bundleId: "t", context: "AuditQuotingContext",
            aggregates: [minimalAggregate(events: ["FooHappened"])],
            useCases: [], dtos: [], readModels: [rm]
        )
        XCTAssertThrowsError(try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )) { err in
            guard case GenesisError.bundleInvalid(let r) = err else {
                XCTFail("expected bundleInvalid")
                return
            }
            XCTAssertTrue(r.contains("missing 'key'"))
        }
    }

    func testMissingEventRefsThrows() throws {
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: "agg-AuditQuoting",
            name: "GetThing", eventNames: ["FooHappened"],
            aggregateRef: "AuditQuoting",
            key: ReadModelKey(field: "id", type: "String", fromEventPayload: "id"),
            storedFields: [],
            eventRefs: [],  // legacy minimal shape missing sourceAggregate
            comment: nil
        )
        let bundle = FullBundle(
            manifestVersion: 1, bundleId: "t", context: "AuditQuotingContext",
            aggregates: [minimalAggregate(events: ["FooHappened"])],
            useCases: [], dtos: [], readModels: [rm]
        )
        XCTAssertThrowsError(try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )) { err in
            guard case GenesisError.bundleInvalid(let r) = err else {
                XCTFail("expected bundleInvalid")
                return
            }
            XCTAssertTrue(r.contains("events[].sourceAggregate"))
        }
    }

    // MARK: - Event name normalization (audit H2)

    func testEventNameNormalizedUpperCamel() throws {
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: "agg-AuditQuoting",
            name: "GetThing", eventNames: ["userAccessProfileCreated"],
            aggregateRef: "AuditQuoting",
            key: ReadModelKey(field: "id", type: "String", fromEventPayload: "userId"),
            storedFields: [],
            eventRefs: [ReadModelEventRef(name: "userAccessProfileCreated", sourceAggregate: "AuditQuoting")],
            comment: nil
        )
        let bundle = FullBundle(
            manifestVersion: 1, bundleId: "t", context: "AuditQuotingContext",
            aggregates: [minimalAggregate(events: ["userAccessProfileCreated"])],
            useCases: [], dtos: [], readModels: [rm]
        )
        let outputs = try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )
        let pr = outputs.first(where: { $0.path.hasSuffix("Presenter.swift") })!
        XCTAssertTrue(pr.content.contains("event: UserAccessProfileCreated"),
            "lower-camel bundle name must normalize to UpperCamel in Presenter when() signature")
        let js = outputs.first(where: { $0.path.hasSuffix(".js") })!
        XCTAssertTrue(js.content.contains("UserAccessProfileCreated: handleEvent"),
            "JS handler key uses normalized UpperCamel")
    }

    // MARK: - Stream prefix (audit L2 edge cases)

    func testStreamPrefixAliasOpportunity() throws {
        let p = try ReadModelRenderer.streamPrefix(contextName: "OpportunityContext")
        XCTAssertEqual(p.projection, "OC_")
        XCTAssertEqual(p.sourceCategory, "OC")
    }

    func testStreamPrefixFallbackIAMContext() throws {
        let p = try ReadModelRenderer.streamPrefix(contextName: "IAMContext")
        XCTAssertEqual(p.projection, "IAM_")
        XCTAssertEqual(p.sourceCategory, "IAM")
    }

    func testStreamPrefixFallbackMyApp() throws {
        let p = try ReadModelRenderer.streamPrefix(contextName: "MyApp")
        XCTAssertEqual(p.projection, "MY_APP_")
        XCTAssertEqual(p.sourceCategory, "MY_APP")
    }

    func testStreamPrefixFallbackBillingContext() throws {
        let p = try ReadModelRenderer.streamPrefix(contextName: "BillingContext")
        XCTAssertEqual(p.projection, "BILLING_")
        XCTAssertEqual(p.sourceCategory, "BILLING")
    }

    func testStreamPrefixContextOnlyThrows() throws {
        XCTAssertThrowsError(try ReadModelRenderer.streamPrefix(contextName: "Context")) { err in
            guard case GenesisError.bundleInvalid(let r) = err else { XCTFail(); return }
            XCTAssertTrue(r.contains("must not equal 'Context'"))
        }
    }

    // MARK: - Scaffold-once (audit H6)

    func testPresenterScaffoldOnceSkipsExisting() throws {
        let bundle = minimalBundle(readModels: [happyReadModel()])
        let existing: Set<String> = [
            "Sources/AuditQuotingAggregate/Usecase/Projector/GetQuotingProofs/GetQuotingProofsPresenter.swift"
        ]
        let outputs = try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext",
            adapter: defaultAdapter(), existingPresenterPaths: existing
        )
        let paths = Set(outputs.map { $0.path })
        XCTAssertFalse(paths.contains("Sources/AuditQuotingAggregate/Usecase/Projector/GetQuotingProofs/GetQuotingProofsPresenter.swift"),
            "Presenter must be skipped when existing — scaffold-once protects user edits")
        // ReadModel + JS still emitted
        XCTAssertEqual(outputs.count, 2)
        XCTAssertTrue(paths.contains("Sources/AuditQuotingAggregate/Usecase/Projector/GetQuotingProofs/QuotingProofsReadModel.swift"))
        XCTAssertTrue(paths.contains("projections/AUDIT_QUOTING_GetQuotingProofsProjection.js"))
    }

    // MARK: - StoredFields default heuristic (audit M3)

    func testStoredFieldDefaultsByType() throws {
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: "agg-AuditQuoting",
            name: "GetSnapshot", eventNames: ["Happened"],
            aggregateRef: "AuditQuoting",
            key: ReadModelKey(field: "id", type: "String", fromEventPayload: "id"),
            storedFields: [
                ReadModelStoredField(name: "optString", type: "String?", defaultValue: nil),
                ReadModelStoredField(name: "optGeneric", type: "Optional<Int>", defaultValue: nil),
                ReadModelStoredField(name: "arrInline", type: "[String]", defaultValue: nil),
                ReadModelStoredField(name: "dictInline", type: "[String: Int]", defaultValue: nil),
                ReadModelStoredField(name: "arrGeneric", type: "Array<Int>", defaultValue: nil),
                ReadModelStoredField(name: "dictGeneric", type: "Dictionary<String, Int>", defaultValue: nil),
                ReadModelStoredField(name: "setT", type: "Set<String>", defaultValue: nil),
                ReadModelStoredField(name: "explicit", type: "Int", defaultValue: "42"),
            ],
            eventRefs: [ReadModelEventRef(name: "Happened", sourceAggregate: "AuditQuoting")],
            comment: nil
        )
        let bundle = FullBundle(
            manifestVersion: 1, bundleId: "t", context: "AuditQuotingContext",
            aggregates: [minimalAggregate(events: ["Happened"])],
            useCases: [], dtos: [], readModels: [rm]
        )
        let outputs = try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )
        let rmFile = outputs.first(where: { $0.path.hasSuffix("ReadModel.swift") })!
        let c = rmFile.content
        XCTAssertTrue(c.contains("self.optString = nil"))
        XCTAssertTrue(c.contains("self.optGeneric = nil"))
        XCTAssertTrue(c.contains("self.arrInline = []"))
        XCTAssertTrue(c.contains("self.dictInline = [:]"))
        XCTAssertTrue(c.contains("self.arrGeneric = []"))
        XCTAssertTrue(c.contains("self.dictGeneric = [:]"))
        XCTAssertTrue(c.contains("self.setT = Set()"))
        XCTAssertTrue(c.contains("self.explicit = 42"))
    }

    func testStoredFieldNonOptionalNoDefaultThrows() throws {
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: "agg-AuditQuoting",
            name: "GetSnapshot", eventNames: ["Happened"],
            aggregateRef: "AuditQuoting",
            key: ReadModelKey(field: "id", type: "String", fromEventPayload: "id"),
            storedFields: [
                ReadModelStoredField(name: "thing", type: "MyCustomStruct", defaultValue: nil)
            ],
            eventRefs: [ReadModelEventRef(name: "Happened", sourceAggregate: "AuditQuoting")],
            comment: nil
        )
        let bundle = FullBundle(
            manifestVersion: 1, bundleId: "t", context: "AuditQuotingContext",
            aggregates: [minimalAggregate(events: ["Happened"])],
            useCases: [], dtos: [], readModels: [rm]
        )
        XCTAssertThrowsError(try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )) { err in
            guard case GenesisError.bundleInvalid(let r) = err else { XCTFail(); return }
            XCTAssertTrue(r.contains("no inferrable default"))
            XCTAssertTrue(r.contains("MyCustomStruct"))
        }
    }

    // MARK: - empty when() body shape

    func testPresenterEmptyWhenBodyHasUnusedVars() throws {
        let bundle = minimalBundle(readModels: [happyReadModel()])
        let outputs = try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )
        let pr = outputs.first(where: { $0.path.hasSuffix("Presenter.swift") })!
        XCTAssertTrue(pr.content.contains("_ = readModel"))
        XCTAssertTrue(pr.content.contains("_ = event"))
        XCTAssertTrue(pr.content.contains("TODO(Phase 1.g)"))
        // Per event: one when() method
        let whenCount = pr.content.components(separatedBy: "func when(readModel: inout ReadModelType, event:").count - 1
        XCTAssertEqual(whenCount, 2, "expected one when() per selected event")
    }

    // MARK: - Unknown aggregateRef

    func testUnknownAggregateRefThrows() throws {
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: nil,
            name: "GetThing", eventNames: ["FooHappened"],
            aggregateRef: "NonExistent",
            key: ReadModelKey(field: "id", type: "String", fromEventPayload: "id"),
            storedFields: [],
            eventRefs: [ReadModelEventRef(name: "FooHappened", sourceAggregate: "AuditQuoting")],
            comment: nil
        )
        let bundle = minimalBundle(readModels: [rm])
        XCTAssertThrowsError(try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )) { err in
            guard case GenesisError.bundleInvalid(let r) = err else { XCTFail(); return }
            XCTAssertTrue(r.contains("not found in bundle.aggregates[]"))
        }
    }
}
