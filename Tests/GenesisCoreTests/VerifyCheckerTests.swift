import XCTest
@testable import GenesisCore

/// Phase 1.y: pins the genesis-verify detector against the false-positives the audit flagged —
/// it must be COMMENT-aware (test-gen ships the error assertion commented-out) and DISABLED-aware
/// (a .disabled @Test does not count as an enabled invariant test).
final class VerifyCheckerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("VC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // every fixture needs a Package.swift sibling check passes elsewhere; verify() only walks Sources/ + Tests/.
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ rel: String, _ content: String) throws {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - marker detection (excludes comments)

    func testMarkerDetected() throws {
        try write("Sources/AAggregate/Entity/Commands/A+Foo.swift", """
        extension A { func foo() throws { throw GenesisTODO.notImplemented("foo") } }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingMarkers.count, 1)
    }

    func testCommentedMarkerNotCounted() throws {
        try write("Sources/AAggregate/Entity/Commands/A+Foo.swift", """
        extension A { func foo() throws {
            // example: throw GenesisTODO.notImplemented("foo")  <- this is a comment, not a hole
            self.x = 1
        } }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingMarkers.count, 0, "a commented marker line must NOT count as an unfilled hole")
    }

    // MARK: - invariant errorCode coverage (comment + disabled aware)

    private func writeErrorEnum() throws {
        // one case per line, matching AggregateRenderer.renderError's actual output.
        try write("Sources/AAggregate/AError.swift", """
        package enum AError: Error {
            case employeeNotActive
            case permissionNotMatch
            case placeholder
        }
        """)
    }

    func testInvariantUncoveredWhenNoTest() throws {
        try writeErrorEnum()
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(Set(r.uncoveredInvariants), ["employeeNotActive", "permissionNotMatch"],
                       "placeholder excluded; both real codes uncovered (no tests)")
    }

    func testEnabledTestCoversInvariant() throws {
        try writeErrorEnum()
        try write("Tests/ATests/PromoteUserTests.swift", """
        import Testing
        @Test func rejectsResigned() async throws {
            #expect(error?.error == .employeeNotActive)
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertFalse(r.uncoveredInvariants.contains("employeeNotActive"), "enabled test referencing the code covers it")
        XCTAssertTrue(r.uncoveredInvariants.contains("permissionNotMatch"), "the other code still uncovered")
    }

    func testDisabledTestDoesNotCover() throws {
        try writeErrorEnum()
        try write("Tests/ATests/PromoteUserTests.swift", """
        import Testing
        @Test(.disabled("pending")) func rejectsResigned() async throws {
            #expect(error?.error == .employeeNotActive)
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertTrue(r.uncoveredInvariants.contains("employeeNotActive"),
                      "a .disabled test referencing the code must NOT count (the audit's core false-positive)")
    }

    // MARK: - adversarial-verify regressions (Phase 1.y impl-verify workflow findings)

    func testQueryErrorNotTreatedAsInvariant() throws {
        // <A>QueryError.swift is a read-side error (case notFound), NOT an aggregate invariant. Its file name
        // suffixes "Error.swift" and sits under *Aggregate, but it must NOT be collected as an invariant code
        // (else genesis verify falsely demands a .notFound test and fails correctly-generated projects).
        try writeErrorEnum()  // AAggregate/AError.swift
        try write("Sources/AAggregate/AQueryError.swift", """
        package enum AQueryError: Error {
            case notFound
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertFalse(r.uncoveredInvariants.contains("notFound"),
                       "read-side <A>QueryError cases must NOT be treated as aggregate invariants")
        XCTAssertEqual(Set(r.uncoveredInvariants), ["employeeNotActive", "permissionNotMatch"],
                       "only the <A>Error invariant codes count")
    }

    func testPrefixCollisionDoesNotFalselyCover() throws {
        try writeErrorEnum()  // has employeeNotActive, permissionNotMatch
        // a test referencing only a LONGER symbol must NOT falsely cover the shorter invariant code.
        try write("Tests/ATests/T.swift", """
        import Testing
        @Test func t() async throws {
            #expect(error?.error == .permissionNotMatchExtra)
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertTrue(r.uncoveredInvariants.contains("permissionNotMatch"),
                      ".permissionNotMatchExtra must NOT falsely cover .permissionNotMatch (prefix-collision false-negative)")
    }

    func testCommentedAssertionDoesNotCover() throws {
        try writeErrorEnum()
        // test-gen ships the assertion commented-out inside a disabled stub — must not falsely 'cover'.
        try write("Tests/ATests/PromoteUserTests.swift", """
        import Testing
        @Test func placeholder() async throws {
            // #expect(error?.error == .employeeNotActive)   <- commented template, not a real assertion
            Issue.record("pending")
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertTrue(r.uncoveredInvariants.contains("employeeNotActive"),
                      "a commented-out assertion must NOT count as coverage")
    }

    // MARK: - Phase 1.z FIX-1 (string-literal awareness) + FIX-2 (test-side Given holes)

    func testStringLiteralCodeDoesNotCover() throws {
        try writeErrorEnum()  // employeeNotActive, permissionNotMatch
        // FIX-1: a .code token that appears ONLY inside a genesisTODO arrange-thunk MESSAGE (a string
        // literal) must NOT earn coverage — only a live assertion does.
        try write("Tests/ATests/PromoteUserTests.swift", """
        import Testing
        @Test func pendingArrange() async throws {
            let input: Int = try genesisTODO("GENESIS-ARRANGE: value tripping .employeeNotActive")
            _ = input
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertTrue(r.uncoveredInvariants.contains("employeeNotActive"),
                      "a .code token only inside a thunk message string must NOT count as coverage (FIX-1)")
    }

    func testEnabledTestHoleFlagged() throws {
        // FIX-2: a genesisTODO( arrange-thunk left in an ENABLED @Test is a remaining test-side Given hole.
        try write("Tests/ATests/PromoteUserTests.swift", """
        import Testing
        @Test func pendingArrange() async throws {
            let input: Int = try genesisTODO("GENESIS-ARRANGE: dictate Given")
            _ = input
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingTestHoles.count, 1, "a genesisTODO( call in an enabled @Test is a remaining test hole (FIX-2)")
        XCTAssertFalse(r.passed, "remainingTestHoles must fail the gate")
    }

    func testDisabledOrCommentedHoleNotFlagged() throws {
        // a genesisTODO in a .disabled test, or commented out, is NOT a live hole.
        try write("Tests/ATests/T.swift", """
        import Testing
        @Test(.disabled("pending")) func d() async throws {
            let input: Int = try genesisTODO("GENESIS-ARRANGE: in a disabled test")
            _ = input
        }
        @Test func c() async throws {
            // let input: Int = try genesisTODO("commented out")
            #expect(Bool(true))
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingTestHoles.count, 0, "genesisTODO in a .disabled test or a comment is not a live hole")
    }

    func testStringLiteralGenesisTODOMentionNotFlagged() throws {
        // FIX-1: a string literal that merely MENTIONS genesisTODO( is not a live hole.
        try write("Tests/ATests/T.swift", """
        import Testing
        @Test func t() async throws {
            let note = "remember to call genesisTODO( ) when stubbing"
            _ = note
            #expect(Bool(true))
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingTestHoles.count, 0, "a genesisTODO( mention inside a string literal is not a live hole (FIX-1)")
    }

    func testThunkMessageWithDisabledTokenNotFalseExcluded() throws {
        try writeErrorEnum()
        // FIX-1: a thunk message containing the token '.disabled' must NOT cause the whole enabled @Test
        // region to be dropped as a disabled test — its live assertion must still earn coverage, and its
        // genesisTODO thunk must still be flagged.
        try write("Tests/ATests/T.swift", """
        import Testing
        @Test func rejects() async throws {
            let input: Int = try genesisTODO("GENESIS-ARRANGE: when account .disabled then trips")
            _ = input
            #expect(error?.error == .employeeNotActive)
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertFalse(r.uncoveredInvariants.contains("employeeNotActive"),
                       "a thunk message containing token '.disabled' must NOT false-exclude the enabled @Test (its live assertion still covers)")
        XCTAssertEqual(r.remainingTestHoles.count, 1,
                       "and the genesisTODO thunk in that same enabled @Test is still flagged as a hole")
    }

    // MARK: - impl-verify regressions: tricky string literals must NOT hide a real hole (DANGEROUS false-green)

    func testTripleQuotedStringDoesNotHideHole() throws {
        // F1: a triple-quoted string whose content has an odd number of bare quotes desynced the old naive
        // two-pass strip, blanking a subsequent real genesisTODO( hole. The single-pass lexer must not desync.
        let body = [
            "import Testing",
            "@Test func t() async throws {",
            "    let doc = \"\"\"",
            "    he said \"hi to genesisTODO and .employeeNotActive",   // odd bare quote + decoy tokens inside the string
            "    \"\"\"",
            "    _ = doc",
            "    let input: Int = try genesisTODO(\"GENESIS-ARRANGE: REAL unfilled hole after a triple-quoted string\")",
            "    _ = input",
            "}",
        ].joined(separator: "\n")
        try writeErrorEnum()
        try write("Tests/ATests/T.swift", body)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertGreaterThanOrEqual(r.remainingTestHoles.count, 1,
            "a real genesisTODO hole after a triple-quoted string must NOT be hidden (dangerous false-green)")
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.uncoveredInvariants.contains("employeeNotActive"),
            "the .employeeNotActive token lived ONLY inside the triple-quoted string → must not count as coverage")
    }

    func testRawStringDoesNotHideHole() throws {
        // F2: a raw string #"..."# containing a bare quote desynced the old strip. Lexer must handle # delimiters.
        let body = [
            "import Testing",
            "@Test func t() async throws {",
            "    let doc = #\"a raw \" string with one bare quote and genesisTODO( mention\"#",
            "    _ = doc",
            "    let input: Int = try genesisTODO(\"GENESIS-ARRANGE: REAL unfilled hole after a raw string\")",
            "    _ = input",
            "}",
        ].joined(separator: "\n")
        try write("Tests/ATests/T.swift", body)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingTestHoles.count, 1,
            "a real genesisTODO hole after a raw string must be detected; the in-string genesisTODO( mention must NOT")
        XCTAssertFalse(r.passed)
    }

    func testSlashSlashInStringDoesNotHideHole() throws {
        // F3: a // inside a string literal, on the same line BEFORE a genesisTODO( call. The old stripComments
        // (run first, not string-aware) truncated the line and hid the hole. Single-pass lexer treats // inside
        // a string as string content.
        try write("Tests/ATests/T.swift", """
        import Testing
        @Test func t() async throws {
            let note = "http://example.com/x"; let input: Int = try genesisTODO("GENESIS-ARRANGE: REAL hole after a URL string")
            _ = note; _ = input
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingTestHoles.count, 1,
            "a genesisTODO hole after a //-containing string on the same line must NOT be truncated away (dangerous false-green)")
        XCTAssertFalse(r.passed)
    }

    // MARK: - M2: /api fatalError→GenesisTODO migration is caught by the existing Sources/ marker scan

    func testMigratedApiHandlerThrowStubIsDetectedAsMarker() throws {
        // The migrated ApiHandlerMethod stub uses the throwing-IIFE form (T4). It puts
        // `throw GenesisTODO.notImplemented(...)` on ONE physical line, so the existing Sources/ marker scan
        // must catch it — i.e. an unfilled /api write-side stub does NOT false-green genesis verify.
        try write("Sources/AAggregate/Adapter/ApiHandler.swift", """
        package struct ApiHandler {
            package func grantPrivilege(_ input: Int) async throws -> Int {
                let asInput: Int = try { () throws -> Int in
                    throw GenesisTODO.notImplemented("TODO(/api skill): construct GrantPrivilegeApplicationServiceInput from payload")
                }()
                return asInput
            }
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingMarkers.count, 1,
            "an unfilled /api throwing-IIFE GenesisTODO stub must be caught by the Sources/ marker scan (no false-green)")
        XCTAssertFalse(r.passed)
    }

    func testFilledApiHandlerHasNoMarker() throws {
        // Once /api fills the body (no GenesisTODO.notImplemented), the stub no longer contributes a marker.
        try write("Sources/AAggregate/Adapter/ApiHandler.swift", """
        package struct ApiHandler {
            package func grantPrivilege(_ input: Int) async throws -> Int {
                let asInput = GrantPrivilegeApplicationServiceInput(value: input)
                return asInput.value
            }
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingMarkers.count, 0,
            "a filled /api handler (no GenesisTODO.notImplemented) must not be flagged as an unfilled marker")
    }

    // MARK: - read-side holes (Presenter when() stubs + read-side AS fatalError)

    private let presenterPath = "Sources/AAggregate/Usecase/Projector/GetFoo/GetFooPresenter.swift"

    private func presenter(_ whens: String) -> String {
        """
        package struct GetFooPresenter: Presenter {
            package typealias ReadModelType = FooReadModel
        \(whens)
        }
        """
    }

    func testUnfilledPresenterWhenIsHole() throws {
        try write(presenterPath, presenter("""
            package func when(readModel: inout ReadModelType, event: FooCreated) throws {
                // TODO(Phase 1.g): mutation logic not yet filled. Run `/readmodel-mutation GetFoo`
                _ = readModel
                _ = event
            }
        """))
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingReadSideHoles.count, 1)
        XCTAssertEqual(r.remainingReadSideHoles.first?.file, presenterPath)
        XCTAssertTrue(r.remainingReadSideHoles.first?.snippet.contains("FooCreated") ?? false)
        XCTAssertFalse(r.passed)
    }

    func testHalfFilledPresenterWhenIsHole() throws {
        // only one placeholder left
        try write(presenterPath, presenter("""
            package func when(readModel: inout ReadModelType, event: FooCreated) throws {
                _ = event
            }
            package func when(readModel: inout ReadModelType, event: FooRenamed) throws {
                let x = event.name
            }
        """))
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingReadSideHoles.count, 2,
            "a single leftover placeholder, and a body with no mutation and no no-op marker, are both half-filled holes")
    }

    func testPlaceholderPlusMutationIsHole() throws {
        try write(presenterPath, presenter("""
            package func when(readModel: inout ReadModelType, event: FooCreated) throws {
                _ = readModel
                _ = event
                readModel.name = event.name
            }
        """))
        XCTAssertEqual(VerifyChecker.verify(projectRoot: tmp).remainingReadSideHoles.count, 1)
    }

    func testFilledPresenterWhenIsNotHole() throws {
        try write(presenterPath, presenter("""
            package func when(readModel: inout ReadModelType, event: FooCreated) throws {
                readModel.fooId = event.fooId
                readModel.name = event.name
            }
            package func when(readModel: inout ReadModelType, event: FooItemAdded) throws {
                readModel.items.append(.init(id: event.id))
            }
            package func when(readModel: inout ReadModelType, event: FooItemRemoved) throws {
                readModel.items.removeAll { $0.id == event.id }
            }
            package func when(readModel: inout ReadModelType, event: FooItemEdited) throws {
                guard let i = readModel.items.firstIndex(where: { $0.id == event.id }) else { return }
                readModel.items[i].name = event.name
            }
        """))
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingReadSideHoles.count, 0)
    }

    func testNoOpMarkerIsNotHole() throws {
        try write(presenterPath, presenter("""
            package func when(readModel: inout ReadModelType, event: FooRetired) throws {
                // readmodel-mutation: no-op — FooRetired 不改變任何 read model 欄位（使用者確認）
            }
        """))
        XCTAssertEqual(VerifyChecker.verify(projectRoot: tmp).remainingReadSideHoles.count, 0)
    }

    func testPlaceholderMentionedOnlyInCommentOrStringIsNotHole() throws {
        try write(presenterPath, presenter("""
            package func when(readModel: inout ReadModelType, event: FooCreated) throws {
                // old stub was: _ = readModel; _ = event
                let note = "_ = readModel"
                /* _ = event */
                readModel.name = event.name + note
            }
        """))
        XCTAssertEqual(VerifyChecker.verify(projectRoot: tmp).remainingReadSideHoles.count, 0,
            "placeholder tokens inside comments/strings must not count (sanitized-content judgement)")
    }

    func testNoOpMarkerInsideStringDoesNotCount() throws {
        // the no-op marker is a COMMENT; a string literal that merely spells it must not silence the hole.
        try write(presenterPath, presenter("""
            package func when(readModel: inout ReadModelType, event: FooCreated) throws {
                let s = "// readmodel-mutation: no-op"
                _ = s
            }
        """))
        XCTAssertEqual(VerifyChecker.verify(projectRoot: tmp).remainingReadSideHoles.count, 1)
    }

    func testCommentedOutWhenIsNotChecked() throws {
        try write(presenterPath, presenter("""
            // package func when(readModel: inout ReadModelType, event: FooCreated) throws { _ = readModel; _ = event }
        """))
        XCTAssertEqual(VerifyChecker.verify(projectRoot: tmp).remainingReadSideHoles.count, 0)
    }

    func testReadSideApplicationServiceFatalErrorIsHole() throws {
        try write("Sources/AAggregate/Adapter/GetFoo/GetFooApplicationService.swift", """
        package struct GetFooApplicationService {
            package func execute(input: Input) async throws -> Output {
                // TODO(/presenter-fill skill): fetch via GetFooPresenter
                fatalError("TODO(/presenter-fill skill): execute body for GetFooApplicationService")
            }
        }
        """)
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingReadSideHoles.count, 1, "only the live fatalError( line counts, not the comment above it")
        XCTAssertTrue(r.remainingReadSideHoles.first?.snippet.contains("TODO(/presenter-fill") ?? false)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.remainingMarkers.count, 0, "the read-side AS hole is its own category")
    }

    func testPresenterFillMentionedInCommentOrStringIsNotHole() throws {
        try write("Sources/AAggregate/Adapter/GetFoo/GetFooApplicationService.swift", """
        package struct GetFooApplicationService {
            package func execute(input: Input) async throws -> Output {
                // was: fatalError("TODO(/presenter-fill skill)")  — filled by /presenter-fill
                let doc = "fatalError(\"TODO(/presenter-fill skill)\")"
                let other = "TODO(/presenter-fill skill)"
                return Output(doc: doc, other: other)
            }
            func unrelated() { fatalError("unreachable") }
        }
        """)
        XCTAssertEqual(VerifyChecker.verify(projectRoot: tmp).remainingReadSideHoles.count, 0)
    }

    func testReadSideHolesDoNotChangeOtherCategories() throws {
        try write(presenterPath, presenter("""
            package func when(readModel: inout ReadModelType, event: FooCreated) throws {
                _ = readModel
                _ = event
            }
        """))
        let r = VerifyChecker.verify(projectRoot: tmp)
        XCTAssertEqual(r.remainingMarkers.count, 0)
        XCTAssertEqual(r.uncoveredInvariants.count, 0)
        XCTAssertEqual(r.remainingTestHoles.count, 0)
    }
}
