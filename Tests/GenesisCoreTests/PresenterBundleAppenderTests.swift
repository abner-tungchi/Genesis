import XCTest
@testable import GenesisCore

final class PresenterBundleAppenderTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func loadInputBundle() throws -> FullBundle {
        try BundleParser.parseFull(at: fixtureURL("presenter-skill-input-bundle.json"))
    }

    private func loadAnswers() throws -> PresenterAnswers {
        let data = try Data(contentsOf: fixtureURL("presenter-skill-answers.json"))
        return try JSONDecoder().decode(PresenterAnswers.self, from: data)
    }

    // MARK: - Happy paths

    func testAppendHappyPathArrayOutput() throws {
        let input = try loadInputBundle()
        let answers = try loadAnswers()
        let appended = try PresenterBundleAppender.append(bundle: input, answers: answers)
        XCTAssertEqual(appended.presenters.count, 1)
        let p = appended.presenters[0]
        XCTAssertEqual(p.name, "GetQuotingProofs")
        XCTAssertEqual(p.readModelRef, "GetQuotingProofs")
        XCTAssertEqual(p.aggregateRef, "AuditQuoting")
        XCTAssertEqual(p.output.kind, .array)
        XCTAssertEqual(p.output.elementType, "QuotingProofDto")
        XCTAssertEqual(p.output.elementSource, "proofs")
        XCTAssertEqual(p.endpoint.method, "GET")
        XCTAssertTrue(p.endpoint.path.contains("/audit-quoting/"))
        XCTAssertTrue(p.endpoint.path.contains("{auditQuotingId}"))
        XCTAssertTrue(p.endpoint.path.contains("quoting-proofs"))
    }

    func testAppendHappyPathSingleOutput() throws {
        let input = try loadInputBundle()
        let answers = PresenterAnswers(
            readModelRef: "GetQuotingProofs",
            name: "GetAccountingType",
            outputKind: "single",
            elementType: "AccountingTypeDto",
            elementSource: "accountingType",
            isOptional: true,
            inputFields: [.init(name: "auditQuotingId", type: "String")]
        )
        let appended = try PresenterBundleAppender.append(bundle: input, answers: answers)
        let p = appended.presenters[0]
        XCTAssertEqual(p.output.kind, .single)
        XCTAssertTrue(p.output.isOptional)
        XCTAssertEqual(p.output.elementType, "AccountingTypeDto")
    }

    func testAppendHappyPathScalarOutput() throws {
        let input = try loadInputBundle()
        let answers = PresenterAnswers(
            readModelRef: "GetQuotingProofs",
            name: "GetFontSize",
            outputKind: "scalar",
            elementType: "String",
            elementSource: "fontSize",
            isOptional: true
        )
        let appended = try PresenterBundleAppender.append(bundle: input, answers: answers)
        XCTAssertEqual(appended.presenters[0].output.kind, .scalar)
    }

    // MARK: - Validation

    func testInvalidNameRejected() throws {
        let bad = PresenterAnswers(
            readModelRef: "GetQuotingProofs", name: "invalidName",
            outputKind: "array", elementType: "X", elementSource: "y"
        )
        XCTAssertThrowsError(try PresenterBundleAppender.append(bundle: try loadInputBundle(), answers: bad)) { err in
            guard case PresenterAppendError.invalidName = err else { XCTFail("\(err)"); return }
        }
    }

    func testUnknownReadModelRefRejected() throws {
        let bad = PresenterAnswers(
            readModelRef: "Nonexistent", name: "GetSomeValue",
            outputKind: "array", elementType: "T", elementSource: "f"
        )
        XCTAssertThrowsError(try PresenterBundleAppender.append(bundle: try loadInputBundle(), answers: bad)) { err in
            guard case PresenterAppendError.unknownReadModel = err else { XCTFail("\(err)"); return }
        }
    }

    func testInvalidOutputKindRejected() throws {
        let bad = PresenterAnswers(
            readModelRef: "GetQuotingProofs", name: "GetSomeValue",
            outputKind: "list", elementType: "T", elementSource: "f"
        )
        XCTAssertThrowsError(try PresenterBundleAppender.append(bundle: try loadInputBundle(), answers: bad)) { err in
            guard case PresenterAppendError.invalidOutputKind = err else { XCTFail("\(err)"); return }
        }
    }

    func testDuplicateNameRejected() throws {
        let input = try loadInputBundle()
        let base = try loadAnswers()
        let after1 = try PresenterBundleAppender.append(bundle: input, answers: base)
        XCTAssertThrowsError(try PresenterBundleAppender.append(bundle: after1, answers: base)) { err in
            guard case PresenterAppendError.duplicateName = err else { XCTFail("\(err)"); return }
        }
    }

    func testDuplicateNameOverwriteAccepted() throws {
        let input = try loadInputBundle()
        let base = try loadAnswers()
        let after1 = try PresenterBundleAppender.append(bundle: input, answers: base)
        let overwritten = PresenterAnswers(
            readModelRef: base.readModelRef, name: base.name,
            outputKind: "scalar", elementType: "Int", elementSource: "count",
            isOptional: false, overwriteIfExists: true
        )
        let after2 = try PresenterBundleAppender.append(bundle: after1, answers: overwritten)
        XCTAssertEqual(after2.presenters.count, 1, "overwrite must not duplicate")
        XCTAssertEqual(after2.presenters[0].output.kind, .scalar)
    }

    func testMissingElementTypeRejected() throws {
        let bad = PresenterAnswers(
            readModelRef: "GetQuotingProofs", name: "GetSomeValue",
            outputKind: "array", elementType: "", elementSource: "f"
        )
        XCTAssertThrowsError(try PresenterBundleAppender.append(bundle: try loadInputBundle(), answers: bad)) { err in
            guard case PresenterAppendError.missingElementType = err else { XCTFail("\(err)"); return }
        }
    }

    func testInvalidInputFieldRejected() throws {
        let bad = PresenterAnswers(
            readModelRef: "GetQuotingProofs", name: "GetSomeValue",
            outputKind: "array", elementType: "T", elementSource: "f",
            inputFields: [.init(name: "Bad-Name", type: "String")]
        )
        XCTAssertThrowsError(try PresenterBundleAppender.append(bundle: try loadInputBundle(), answers: bad)) { err in
            guard case PresenterAppendError.invalidInputField = err else { XCTFail("\(err)"); return }
        }
    }

    func testDuplicateInputFieldRejected() throws {
        let bad = PresenterAnswers(
            readModelRef: "GetQuotingProofs", name: "GetSomeValue",
            outputKind: "array", elementType: "T", elementSource: "f",
            inputFields: [
                .init(name: "x", type: "String"),
                .init(name: "x", type: "Int"),
            ]
        )
        XCTAssertThrowsError(try PresenterBundleAppender.append(bundle: try loadInputBundle(), answers: bad)) { err in
            guard case PresenterAppendError.invalidInputField(_, let reason) = err else { XCTFail("\(err)"); return }
            XCTAssertTrue(reason.contains("duplicate"))
        }
    }

    // MARK: - Helpers

    func testKebabCase() {
        XCTAssertEqual(PresenterBundleAppender.kebabCase("AuditQuoting"), "audit-quoting")
        XCTAssertEqual(PresenterBundleAppender.kebabCase("XMLAPIClient"), "x-m-l-a-p-i-client")
    }

    func testStripGetPrefix() {
        XCTAssertEqual(PresenterBundleAppender.stripGetPrefix("GetFoo"), "Foo")
        XCTAssertEqual(PresenterBundleAppender.stripGetPrefix("Foo"), "Foo")
    }
}
