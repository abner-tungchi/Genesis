import XCTest
@testable import GenesisCore

final class ReadModelBundleAppenderTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func loadInputBundle() throws -> FullBundle {
        try BundleParser.parseFull(at: fixtureURL("readmodel-skill-input-bundle.json"))
    }

    private func loadAnswers() throws -> ReadModelAnswers {
        let data = try Data(contentsOf: fixtureURL("readmodel-skill-answers.json"))
        return try JSONDecoder().decode(ReadModelAnswers.self, from: data)
    }

    private func loadExpectedBundle() throws -> FullBundle {
        try BundleParser.parseFull(at: fixtureURL("readmodel-skill-expected-output-bundle.json"))
    }

    // MARK: - Happy path

    func testAppendHappyPathProducesExpectedBundle() throws {
        let input = try loadInputBundle()
        let answers = try loadAnswers()
        let appended = try ReadModelBundleAppender.append(bundle: input, answers: answers)
        let expected = try loadExpectedBundle()

        XCTAssertEqual(appended.readModels.count, 1)
        XCTAssertEqual(appended.readModels.count, expected.readModels.count)
        XCTAssertEqual(appended.readModels.first?.name, expected.readModels.first?.name)
        XCTAssertEqual(appended.readModels.first?.aggregateRef, expected.readModels.first?.aggregateRef)
        XCTAssertEqual(appended.readModels.first?.key, expected.readModels.first?.key)
        XCTAssertEqual(appended.readModels.first?.eventRefs, expected.readModels.first?.eventRefs)
        XCTAssertEqual(appended.readModels.first?.storedFields, expected.readModels.first?.storedFields)
        XCTAssertEqual(appended.readModels.first?.comment, expected.readModels.first?.comment)
    }

    func testAppendDoesNotMutateOtherBundleFields() throws {
        let input = try loadInputBundle()
        let answers = try loadAnswers()
        let appended = try ReadModelBundleAppender.append(bundle: input, answers: answers)

        XCTAssertEqual(appended.manifestVersion, input.manifestVersion)
        XCTAssertEqual(appended.bundleId, input.bundleId)
        XCTAssertEqual(appended.context, input.context)
        XCTAssertEqual(appended.aggregates, input.aggregates)
        XCTAssertEqual(appended.useCases, input.useCases)
        XCTAssertEqual(appended.dtos, input.dtos)
    }

    // MARK: - Validation: name

    func testInvalidNameRejected() throws {
        let input = try loadInputBundle()
        var answers = try loadAnswers()
        // Reflection-free patch: rebuild with invalid name
        answers = ReadModelAnswers(
            aggregateRef: answers.aggregateRef,
            selectedEvents: answers.selectedEvents,
            name: "invalidName",  // no Get prefix
            keyField: answers.keyField,
            keyType: answers.keyType,
            keyFromPayload: answers.keyFromPayload,
            storedFields: answers.storedFields,
            comment: answers.comment,
            overwriteIfExists: answers.overwriteIfExists
        )
        XCTAssertThrowsError(try ReadModelBundleAppender.append(bundle: input, answers: answers)) { err in
            guard case ReadModelAppendError.invalidName = err else {
                XCTFail("expected invalidName, got \(err)")
                return
            }
        }
    }

    // MARK: - Validation: duplicate name

    func testDuplicateNameRejectedWhenOverwriteFalse() throws {
        let input = try loadInputBundle()
        let answers = try loadAnswers()
        let after1 = try ReadModelBundleAppender.append(bundle: input, answers: answers)
        XCTAssertThrowsError(try ReadModelBundleAppender.append(bundle: after1, answers: answers)) { err in
            guard case ReadModelAppendError.duplicateName(let n) = err else {
                XCTFail("expected duplicateName, got \(err)")
                return
            }
            XCTAssertEqual(n, "GetQuotingProofs")
        }
    }

    func testDuplicateNameAcceptedWhenOverwriteTrue() throws {
        let input = try loadInputBundle()
        let base = try loadAnswers()
        let after1 = try ReadModelBundleAppender.append(bundle: input, answers: base)

        let overwritten = ReadModelAnswers(
            aggregateRef: base.aggregateRef,
            selectedEvents: base.selectedEvents,
            name: base.name,
            keyField: base.keyField,
            keyType: base.keyType,
            keyFromPayload: base.keyFromPayload,
            storedFields: [
                ReadModelAnswers.StoredFieldChoice(name: "newField", type: "Int?", defaultValue: nil)
            ],
            comment: "second pass",
            overwriteIfExists: true
        )
        let after2 = try ReadModelBundleAppender.append(bundle: after1, answers: overwritten)
        XCTAssertEqual(after2.readModels.count, 1, "overwrite must not duplicate")
        XCTAssertEqual(after2.readModels.first?.storedFields.first?.name, "newField")
        XCTAssertEqual(after2.readModels.first?.comment, "second pass")
    }

    // MARK: - Validation: empty events

    func testEmptyEventsRejected() throws {
        let input = try loadInputBundle()
        let base = try loadAnswers()
        let empty = ReadModelAnswers(
            aggregateRef: base.aggregateRef,
            selectedEvents: [],
            name: base.name,
            keyField: base.keyField,
            keyType: base.keyType,
            keyFromPayload: base.keyFromPayload,
            storedFields: base.storedFields,
            comment: base.comment,
            overwriteIfExists: false
        )
        XCTAssertThrowsError(try ReadModelBundleAppender.append(bundle: input, answers: empty)) { err in
            guard case ReadModelAppendError.emptyEvents = err else {
                XCTFail("expected emptyEvents, got \(err)")
                return
            }
        }
    }

    // MARK: - Validation: unknown aggregate

    func testUnknownAggregateRefRejected() throws {
        let input = try loadInputBundle()
        let base = try loadAnswers()
        let bad = ReadModelAnswers(
            aggregateRef: "NonExistentAggregate",
            selectedEvents: base.selectedEvents,
            name: base.name,
            keyField: base.keyField,
            keyType: base.keyType,
            keyFromPayload: base.keyFromPayload,
            storedFields: base.storedFields,
            comment: base.comment,
            overwriteIfExists: false
        )
        XCTAssertThrowsError(try ReadModelBundleAppender.append(bundle: input, answers: bad)) { err in
            guard case ReadModelAppendError.unknownAggregate = err else {
                XCTFail("expected unknownAggregate, got \(err)")
                return
            }
        }
    }

    // MARK: - Validation: storedField collides with key

    func testStoredFieldCollidesWithKeyRejected() throws {
        let input = try loadInputBundle()
        let base = try loadAnswers()
        let bad = ReadModelAnswers(
            aggregateRef: base.aggregateRef,
            selectedEvents: base.selectedEvents,
            name: base.name,
            keyField: "auditQuotingId",
            keyType: base.keyType,
            keyFromPayload: base.keyFromPayload,
            storedFields: [
                ReadModelAnswers.StoredFieldChoice(name: "auditQuotingId", type: "String", defaultValue: nil)
            ],
            comment: base.comment,
            overwriteIfExists: false
        )
        XCTAssertThrowsError(try ReadModelBundleAppender.append(bundle: input, answers: bad)) { err in
            guard case ReadModelAppendError.storedFieldCollidesWithKey = err else {
                XCTFail("expected storedFieldCollidesWithKey, got \(err)")
                return
            }
        }
    }

    // MARK: - Validation: inconsistent payload key

    func testInconsistentPayloadKeyRejected() throws {
        let input = try loadInputBundle()
        let base = try loadAnswers()
        // AccountingTypeEdited payload has "accountingType" not "documentId" — so
        // if we set keyFromPayload="documentId" but include AccountingTypeEdited,
        // the payload check should fail.
        let bad = ReadModelAnswers(
            aggregateRef: base.aggregateRef,
            selectedEvents: [
                .init(name: "AccountingTypeEdited", sourceAggregate: "AuditQuoting"),
                .init(name: "QuotingProofUploadedToGcs", sourceAggregate: "AuditQuoting")
            ],
            name: "GetSomething",
            keyField: "auditQuotingId",
            keyType: "String",
            keyFromPayload: "documentId",  // present in proof event, missing in accounting event
            storedFields: [],
            comment: nil,
            overwriteIfExists: false
        )
        XCTAssertThrowsError(try ReadModelBundleAppender.append(bundle: input, answers: bad)) { err in
            guard case ReadModelAppendError.inconsistentPayloadKey = err else {
                XCTFail("expected inconsistentPayloadKey, got \(err)")
                return
            }
        }
    }

    // MARK: - Cross-aggregate (context-level)

    func testCrossAggregateContextLevel() throws {
        let input = try loadInputBundle()
        let crossAnswers = ReadModelAnswers(
            aggregateRef: "<context-level>",
            selectedEvents: [
                .init(name: "AccountingTypeEdited", sourceAggregate: "AuditQuoting"),
                .init(name: "ServiceItemSelected", sourceAggregate: "QuotingCaseGrouping")
            ],
            name: "GetCrossAggregateSummary",
            keyField: "quotingCaseGroupingId",
            keyType: "String",
            keyFromPayload: "quotingCaseGroupingId",
            storedFields: [],
            comment: nil,
            overwriteIfExists: false
        )
        // AccountingTypeEdited payload doesn't have quotingCaseGroupingId — should
        // throw inconsistentPayloadKey. The cross-aggregate path itself is exercised.
        XCTAssertThrowsError(try ReadModelBundleAppender.append(bundle: input, answers: crossAnswers)) { err in
            guard case ReadModelAppendError.inconsistentPayloadKey = err else {
                XCTFail("expected inconsistentPayloadKey (cross-agg key mismatch), got \(err)")
                return
            }
        }
    }

    func testCrossAggregateContextLevelWithValidKey() throws {
        let input = try loadInputBundle()
        let crossAnswers = ReadModelAnswers(
            aggregateRef: "<context-level>",
            selectedEvents: [
                .init(name: "ServiceItemSelected", sourceAggregate: "QuotingCaseGrouping"),
                .init(name: "ServiceItemUnselected", sourceAggregate: "QuotingCaseGrouping")
            ],
            name: "GetSelectedServiceItems",
            keyField: "quotingCaseGroupingId",
            keyType: "String",
            keyFromPayload: "quotingCaseGroupingId",
            storedFields: [
                ReadModelAnswers.StoredFieldChoice(name: "serviceItemId", type: "String?", defaultValue: nil)
            ],
            comment: nil,
            overwriteIfExists: false
        )
        let after = try ReadModelBundleAppender.append(bundle: input, answers: crossAnswers)
        XCTAssertEqual(after.readModels.first?.aggregateRef, "<context-level>")
        XCTAssertNil(after.readModels.first?.aggregateSpecId, "context-level entries have no specific aggregateSpecId")
        XCTAssertEqual(after.readModels.first?.eventRefs.count, 2)
        XCTAssertEqual(Set(after.readModels.first?.eventRefs.map(\.sourceAggregate) ?? []), ["QuotingCaseGrouping"])
    }

    // MARK: - resolvePayload

    func testResolvePayloadFindsViaUseCases() throws {
        let bundle = try loadInputBundle()
        let payload = ReadModelBundleAppender.resolvePayload(eventName: "AuditQuotingCreated", bundle: bundle)
        XCTAssertEqual(payload.map(\.name), ["quotingId", "createdAt"])
    }

    func testResolvePayloadEmptyForUnknownEvent() throws {
        let bundle = try loadInputBundle()
        let payload = ReadModelBundleAppender.resolvePayload(eventName: "NonexistentEvent", bundle: bundle)
        XCTAssertTrue(payload.isEmpty)
    }

    func testResolvePayloadPicksFirstMatchingUseCase() throws {
        let bundle = try loadInputBundle()
        let payload = ReadModelBundleAppender.resolvePayload(eventName: "AccountingTypeEdited", bundle: bundle)
        XCTAssertEqual(payload.map(\.name), ["quotingId", "accountingType"])
    }

    // MARK: - Event-aggregate consistency (specific aggregateRef)

    func testEventFromWrongAggregateRejected() throws {
        let input = try loadInputBundle()
        let bad = ReadModelAnswers(
            aggregateRef: "AuditQuoting",
            selectedEvents: [
                .init(name: "ServiceItemSelected", sourceAggregate: "QuotingCaseGrouping")  // wrong aggregate
            ],
            name: "GetThing",
            keyField: "quotingCaseGroupingId",
            keyType: "String",
            keyFromPayload: "quotingCaseGroupingId",
            storedFields: [],
            comment: nil,
            overwriteIfExists: false
        )
        XCTAssertThrowsError(try ReadModelBundleAppender.append(bundle: input, answers: bad)) { err in
            guard case ReadModelAppendError.unknownEvent = err else {
                XCTFail("expected unknownEvent (cross-aggregate violation), got \(err)")
                return
            }
        }
    }
}
