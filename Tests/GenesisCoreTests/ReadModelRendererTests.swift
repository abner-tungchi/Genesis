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
        XCTAssertTrue(paths.contains("projections/AQC_GetQuotingProofsProjection.js"))
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
        XCTAssertTrue(pr.content.contains("AQC_"), "ProjectionStreamPrefix = uppercaseLetters(context)+_ (AuditQuotingContext→AQC_)")

        let js = outputs.first(where: { $0.path.hasSuffix("Projection.js") })!
        XCTAssertTrue(js.content.contains("fromStreams([\"$ce-AQCAuditQuoting\"])"),
            "$ce- source stream uses categoryPrefix (no trailing _), ALIGNED with aggregate write category $ce-AQCAuditQuoting")
        XCTAssertTrue(js.content.contains("linkTo(\"AQC_GetQuotingProofs-\""),
            "linkTo uses projectionPrefix (with _)")
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

    // Phase: prefix unified to StreamNaming.categoryPrefix = uppercaseLetters(contextName), aligning the read
    // side to the aggregate write category. OC reproduces "OC" via uppercaseLetters WITHOUT the old alias.
    func testStreamPrefixOpportunity() throws {
        let p = try ReadModelRenderer.streamPrefix(contextName: "OpportunityContext")
        XCTAssertEqual(p.projection, "OC_")
        XCTAssertEqual(p.sourceCategory, "OC")
    }

    func testStreamPrefixIAMContext() throws {
        let p = try ReadModelRenderer.streamPrefix(contextName: "IAMContext")
        XCTAssertEqual(p.projection, "IAMC_")   // aligned with aggregate write category $ce-IAMC<Agg>
        XCTAssertEqual(p.sourceCategory, "IAMC")
    }

    func testStreamPrefixMyApp() throws {
        let p = try ReadModelRenderer.streamPrefix(contextName: "MyApp")
        XCTAssertEqual(p.projection, "MA_")
        XCTAssertEqual(p.sourceCategory, "MA")
    }

    func testStreamPrefixBillingContext() throws {
        let p = try ReadModelRenderer.streamPrefix(contextName: "BillingContext")
        XCTAssertEqual(p.projection, "BC_")
        XCTAssertEqual(p.sourceCategory, "BC")
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
        XCTAssertTrue(paths.contains("projections/AQC_GetQuotingProofsProjection.js"))
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

    // MARK: - Cosmogony bracket notation must be resolved to Swift types

    private func renderRMFile(storedFields: [ReadModelStoredField], keyType: String = "String") throws -> String {
        let rm = ReadModelSpec(
            readModelSpecId: "rm-1", aggregateSpecId: "agg-AuditQuoting",
            name: "GetSnapshot", eventNames: ["Happened"],
            aggregateRef: "AuditQuoting",
            key: ReadModelKey(field: "id", type: keyType, fromEventPayload: "id"),
            storedFields: storedFields,
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
        return outputs.first(where: { $0.path.hasSuffix("ReadModel.swift") })!.content
    }

    func testStoredFieldCosmogonyArrayNotationResolvedToSwiftArray() throws {
        // Shape produced by BundleParser when flattening returnType.fields with a non-primitive type.
        let c = try renderRMFile(storedFields: [
            ReadModelStoredField(name: "permissions", type: "Array[String]?", defaultValue: nil),
        ])
        XCTAssertTrue(c.contains("package var permissions: [String]?"), c)
        XCTAssertTrue(c.contains("self.permissions = nil"), c)
        XCTAssertFalse(c.contains("Array["), c)
    }

    func testStoredFieldNonOptionalCosmogonyArrayGetsEmptyArrayDefault() throws {
        let c = try renderRMFile(storedFields: [
            ReadModelStoredField(name: "ids", type: "Array[String]", defaultValue: nil),
            ReadModelStoredField(name: "tags", type: "Set[String]", defaultValue: nil),
            ReadModelStoredField(name: "grid", type: "Array[Array[Int]]", defaultValue: nil),
        ])
        XCTAssertTrue(c.contains("package var ids: [String]"), c)
        XCTAssertTrue(c.contains("self.ids = []"), c)
        XCTAssertTrue(c.contains("package var tags: Set<String>"), c)
        XCTAssertTrue(c.contains("self.tags = Set()"), c)
        XCTAssertTrue(c.contains("package var grid: [[Int]]"), c)
        XCTAssertTrue(c.contains("self.grid = []"), c)
    }

    func testReadModelKeyTypeCosmogonyNotationResolved() throws {
        let c = try renderRMFile(storedFields: [], keyType: "Array[String]")
        XCTAssertFalse(c.contains("Array["), c)
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

    /// The stub used to say "wait for /readmodel-mutation v2 skill" although the skill already exists (handover run
    /// #33). Each stub now names the exact command to run for this presenter.
    func testPresenterStubCommentPointsToReadmodelMutationCommand() throws {
        let bundle = minimalBundle(readModels: [happyReadModel(name: "GetQuotingProofs")])
        let outputs = try ReadModelRenderer.render(
            bundle: bundle, contextName: "AuditQuotingContext", adapter: defaultAdapter()
        )
        let pr = try XCTUnwrap(outputs.first(where: { $0.path.hasSuffix("GetQuotingProofsPresenter.swift") }))
        XCTAssertEqual(pr.content.components(separatedBy: "Run `/readmodel-mutation GetQuotingProofs`").count - 1, 2,
                       "one pointer per when() stub")
        XCTAssertFalse(pr.content.contains("v2 skill"), pr.content)
        XCTAssertFalse(pr.content.contains("wait for"), pr.content)
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

    // MARK: - M2b read↔write stream-prefix alignment (the bug this task fixes)

    /// A widget bundle in a NON-OC context: the JS projection's `$ce-` source stream must equal the aggregate's
    /// physical write category (`<categoryPrefix><Agg>`). Both now derive from StreamNaming.categoryPrefix
    /// (uppercase letters). Before the fix, ReadModelRenderer used an alias/upperSnake → mismatch → silent empty read.
    private func widgetBundle(fromEventPayload: String) -> FullBundle {
        let agg = AggregateSpec(
            aggregateSpecId: "agg-Widget", name: "Widget", identityName: "widgetId",
            state: [], invariants: [], eventNames: ["WidgetEdited"]
        )
        let uc = UseCaseSpec(
            useCaseSpecId: "uc-edit", aggregateSpecId: "agg-Widget", useCase: "EditWidget", aggregate: "Widget",
            input: [FieldSpec(name: "widgetId", rawType: "String"), FieldSpec(name: "value", rawType: "String")],
            emittedEvent: "WidgetEdited",
            eventPayload: [FieldSpec(name: "widgetId", rawType: "String"), FieldSpec(name: "value", rawType: "String")],
            preconditions: []
        )
        let rm = ReadModelSpec(
            readModelSpecId: "rm-GetWidgetValue", aggregateSpecId: "agg-Widget",
            name: "GetWidgetValue", eventNames: ["WidgetEdited"], aggregateRef: "Widget",
            key: ReadModelKey(field: "widgetId", type: "String", fromEventPayload: fromEventPayload),
            storedFields: [ReadModelStoredField(name: "value", type: "String?", defaultValue: nil)],
            eventRefs: [ReadModelEventRef(name: "WidgetEdited", sourceAggregate: "Widget")],
            comment: nil
        )
        return FullBundle(
            manifestVersion: 1, bundleId: "t", context: "WidgetContext",
            aggregates: [agg], useCases: [uc], dtos: [], readModels: [rm]
        )
    }

    func testReadStreamPrefixAlignsWithWriteCategory() throws {
        let bundle = widgetBundle(fromEventPayload: "widgetId")
        let adapter = Adapter.defaultFor(contextName: "WidgetContext")
        let out = try ReadModelRenderer.render(bundle: bundle, contextName: "WidgetContext", adapter: adapter)
        let js = try XCTUnwrap(out.first { $0.path.hasSuffix("Projection.js") }).content
        // WidgetContext → uppercaseLetters → "WC". Aggregate writes $ce-WCWidget; JS MUST subscribe the same.
        XCTAssertTrue(js.contains("fromStreams([\"$ce-WCWidget\"])"),
            "JS $ce- source stream must equal the aggregate write category $ce-WCWidget (read↔write alignment)")
        XCTAssertTrue(js.contains("linkTo(\"WC_GetWidgetValue-\""))
        XCTAssertTrue(js.contains("event.body[\"widgetId\"]"))
        // pin: read side derives from the SAME single source the aggregate write category uses.
        XCTAssertEqual(try ReadModelRenderer.streamPrefix(contextName: "WidgetContext").sourceCategory,
                       try StreamNaming.categoryPrefix(contextName: "WidgetContext"))
    }

    // MARK: - M2c key.fromEventPayload guard

    func testKeyFromEventPayloadGuardPassesWhenFieldInPayload() throws {
        let bundle = widgetBundle(fromEventPayload: "widgetId")   // widgetId IS in WidgetEdited payload
        XCTAssertNoThrow(try ReadModelRenderer.render(
            bundle: bundle, contextName: "WidgetContext", adapter: Adapter.defaultFor(contextName: "WidgetContext")
        ))
    }

    func testKeyFromEventPayloadGuardThrowsWhenFieldMissing() throws {
        let bundle = widgetBundle(fromEventPayload: "nope")   // not a field of WidgetEdited payload
        XCTAssertThrowsError(try ReadModelRenderer.render(
            bundle: bundle, contextName: "WidgetContext", adapter: Adapter.defaultFor(contextName: "WidgetContext")
        )) { err in
            guard case GenesisError.bundleInvalid(let r) = err else { XCTFail("expected bundleInvalid, got \(err)"); return }
            XCTAssertTrue(r.contains("key.fromEventPayload 'nope'"), "must name the bad field; got: \(r)")
            XCTAssertTrue(r.contains("WidgetEdited"), "must name the event whose payload lacks it; got: \(r)")
        }
    }

    /// MF-A: event names are unique only PER aggregate. A cross-aggregate readModel referencing aggregate B's
    /// `Created` must be validated against B's payload — even if aggregate A also emits `Created` WITH the field.
    /// Without sourceAggregate scoping the guard resolves the first same-named use case (Alpha) → false-pass.
    func testKeyGuardScopesToSourceAggregate() throws {
        let aggA = AggregateSpec(aggregateSpecId: "agg-A", name: "Alpha", identityName: "alphaId",
                                 state: [], invariants: [], eventNames: ["Created"])
        let aggB = AggregateSpec(aggregateSpecId: "agg-B", name: "Beta", identityName: "betaId",
                                 state: [], invariants: [], eventNames: ["Created"])
        // Alpha.Created HAS sharedId; Beta.Created does NOT.
        let ucA = UseCaseSpec(useCaseSpecId: "uc-a", aggregateSpecId: "agg-A", useCase: "CreateAlpha", aggregate: "Alpha",
                              input: [], emittedEvent: "Created",
                              eventPayload: [FieldSpec(name: "sharedId", rawType: "String")], preconditions: [])
        let ucB = UseCaseSpec(useCaseSpecId: "uc-b", aggregateSpecId: "agg-B", useCase: "CreateBeta", aggregate: "Beta",
                              input: [], emittedEvent: "Created",
                              eventPayload: [FieldSpec(name: "betaId", rawType: "String")], preconditions: [])
        // readModel references BETA's Created, keyed on sharedId (present in Alpha, absent in Beta) → must FAIL on Beta.
        let rm = ReadModelSpec(readModelSpecId: "rm-x", aggregateSpecId: "agg-B",
                               name: "GetBetaThing", eventNames: ["Created"], aggregateRef: "Beta",
                               key: ReadModelKey(field: "betaId", type: "String", fromEventPayload: "sharedId"),
                               storedFields: [ReadModelStoredField(name: "v", type: "String?", defaultValue: nil)],
                               eventRefs: [ReadModelEventRef(name: "Created", sourceAggregate: "Beta")],
                               comment: nil)
        let bundle = FullBundle(manifestVersion: 1, bundleId: "t", context: "WidgetContext",
                                aggregates: [aggA, aggB], useCases: [ucA, ucB], dtos: [], readModels: [rm])
        XCTAssertThrowsError(try ReadModelRenderer.render(
            bundle: bundle, contextName: "WidgetContext", adapter: Adapter.defaultFor(contextName: "WidgetContext")
        )) { err in
            guard case GenesisError.bundleInvalid(let r) = err else { XCTFail("expected bundleInvalid, got \(err)"); return }
            XCTAssertTrue(r.contains("sharedId"),
                "guard must validate against Beta's payload (lacks sharedId), not Alpha's same-named event; got: \(r)")
        }
    }
}
