import XCTest
@testable import GenesisCore

final class ProcessRunnerTests: XCTestCase {
    func testRunWithoutTimeoutBackwardCompat() throws {
        // Sanity: existing callers (no timeout) still work, return process exit code + captured streams.
        let result = ProcessRunner.run(executable: "sh", args: ["-c", "echo hi; echo err 1>&2; exit 7"])
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.stdout.contains("hi"))
        XCTAssertTrue(result.stderr.contains("err"))
    }

    func testTimeoutKillsProcess() throws {
        // A normal `sleep` respects SIGTERM, so the first-stage terminate() is sufficient.
        let start = Date()
        let result = ProcessRunner.run(
            executable: "sh",
            args: ["-c", "sleep 30"],
            timeout: 1
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 6, "process should die within timeout + 3s SIGKILL grace")
        XCTAssertNotEqual(result.exitCode, 0, "killed process must not report success")
        XCTAssertTrue(
            result.stderr.contains("timeout after"),
            "stderr should be prefixed with timeout note; got: \(result.stderr)"
        )
    }

    func testTimeoutAttemptsSigkillFallbackOnStubbornChild() throws {
        // Stubborn child: shell traps SIGTERM. SIGKILL is sent to the direct child (sh) after grace.
        // sh dies, but a stubborn descendant (`sleep 30`) may continue holding the inherited
        // stdout/stderr pipes open until it completes — `readDataToEndOfFile()` blocks for EOF.
        // That's a documented Phase 1.e limitation (process-group kill not implemented; see spec).
        // What we DO guarantee: the timeout-flag fires, stderr is prefixed, and the result returns
        // eventually with non-zero exit. We don't assert wall-clock here.
        let result = ProcessRunner.run(
            executable: "sh",
            args: ["-c", "trap '' TERM; sleep 30"],
            timeout: 1
        )
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.stderr.contains("timeout after") && result.stderr.contains("SIGKILL"),
            "stderr should mention timeout + SIGKILL fallback; got: \(result.stderr)"
        )
    }
}
