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
}
