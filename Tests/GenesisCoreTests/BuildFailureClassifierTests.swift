import XCTest
@testable import GenesisCore

/// Phase 1.u.1: the classifier decides whether a `swift build` failure is "only GENESIS-TODO #error
/// domain holes" (keep the project) vs a real breakage (roll back). It is conservative — anything it
/// can't positively verify as a cross-checked #error rolls back. These tests pin the false-positive
/// shapes Codex flagged (ld:/linker/timeout/plain-error/spoof) plus the holes-only happy path.
final class BuildFailureClassifierTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BFC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// Write a swift file (relative to tmp projectRoot) with the given lines.
    private func writeSource(_ relPath: String, lines: [String]) throws {
        let url = tmp.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func classify(_ stderr: String) -> Bool {
        BuildFailureClassifier.buildFailureIsOnlyDomainHoles(stderr: stderr, projectRoot: tmp)
    }

    // MARK: - holes-only → true (with source cross-check)

    func testHolesOnlyWithVerifiedSourceLine() throws {
        try writeSource("Sources/A/Cmd.swift", lines: [
            "extension A {",                                                  // 1
            "    func promoteUser() throws {",                               // 2
            #"        #error("GENESIS-TODO: promoteUser — implement ...")"#, // 3
            "    }",                                                         // 4
        ])
        let stderr = "/private\(tmp.path)/Sources/A/Cmd.swift:3:9: error: GENESIS-TODO: promoteUser — implement ...\n"
            + tmp.appendingPathComponent("Sources/A/Cmd.swift").path + ":3:9: error: GENESIS-TODO: promoteUser — implement ...\n"
        // use the absolute path form the compiler actually emits
        let absStderr = tmp.appendingPathComponent("Sources/A/Cmd.swift").path
            + ":3:9: error: GENESIS-TODO: promoteUser — implement ...\n1 error generated.\n"
        XCTAssertTrue(classify(absStderr), "single verified GENESIS-TODO #error → holes-only; stderr:\n\(absStderr)")
        _ = stderr
    }

    // MARK: - false-positive shapes → false (roll back)

    func testMixedRealErrorRollsBack() throws {
        try writeSource("Sources/A/Cmd.swift", lines: ["x", "y", #"        #error("GENESIS-TODO: ...")"#])
        let p = tmp.appendingPathComponent("Sources/A/Cmd.swift").path
        let stderr = "\(p):3:9: error: GENESIS-TODO: ...\n"
            + "/x/Other.swift:10:5: error: cannot find 'Foo' in scope\n"
        XCTAssertFalse(classify(stderr), "a real error mixed in → roll back")
    }

    func testPlainErrorRollsBack() {
        XCTAssertFalse(classify("error: no such module 'DDDKit'\n"), "plain error: (no file:line) → roll back")
    }

    func testLinkerErrorRollsBack() {
        XCTAssertFalse(classify("ld: error: symbol not found\nlink command failed with exit code 1\n"),
                       "ld:/linker failure → roll back")
    }

    func testTimeoutOrLaunchTextRollsBack() {
        XCTAssertFalse(classify("error: terminated by signal\nprocess launch failed\n"),
                       "launch/timeout-ish text → roll back")
    }

    func testNoErrorLinesRollsBack() {
        XCTAssertFalse(classify("Compiling A\nBuild complete!\n"), "no error lines → not holes-only")
    }

    func testSpoofStringContainingGenesisTodoRollsBack() throws {
        // Source line at the diagnostic location is NOT an #error directive — it's a string literal that
        // merely contains GENESIS-TODO. Cross-check must reject it.
        try writeSource("Sources/A/Spoof.swift", lines: [
            "let msg = \"GENESIS-TODO: not a directive\"",  // 1 — contains text but not #error(
        ])
        let p = tmp.appendingPathComponent("Sources/A/Spoof.swift").path
        let stderr = "\(p):1:11: error: GENESIS-TODO: not a directive\n"
        XCTAssertFalse(classify(stderr), "diagnostic points at a non-#error source line → roll back (anti-spoof)")
    }

    func testUnreadableSourceRollsBack() {
        let stderr = tmp.appendingPathComponent("Sources/Nope.swift").path
            + ":1:1: error: GENESIS-TODO: ...\n"
        XCTAssertFalse(classify(stderr), "diagnostic references a missing file → roll back")
    }
}
