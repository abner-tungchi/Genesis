import XCTest

/// Phase 1.q — genesis --version / check-skills / bundle-parse CLI E2E.
final class CliVersionAndBundleParseTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CliVersionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func fixture(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("fixture \(name).json not found")
        }
        return url
    }

    // MARK: - --version

    func testVersionFlag() throws {
        let result = try CLIRunner.run(["--version"])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "version must be non-empty")
    }

    // MARK: - check-skills (three states)

    func testCheckSkillsNotInstalled() throws {
        // Empty project dir → no sidecar → exit 2 + "not installed"
        let result = try CLIRunner.run([
            "check-skills", "--scope", "project", "--project-dir", tmpDir.path,
        ])
        XCTAssertEqual(result.exitCode, 2, "stderr: \(result.stderr); stdout: \(result.stdout)")
        XCTAssertTrue(result.stdout.contains("not installed"), result.stdout)
    }

    func testCheckSkillsInSync() throws {
        let install = try CLIRunner.run([
            "install-skills", "--scope", "project", "--project-dir", tmpDir.path,
        ])
        XCTAssertEqual(install.exitCode, 0, "install stderr: \(install.stderr)")
        let check = try CLIRunner.run([
            "check-skills", "--scope", "project", "--project-dir", tmpDir.path,
        ])
        XCTAssertEqual(check.exitCode, 0, "stderr: \(check.stderr); stdout: \(check.stdout)")
        XCTAssertTrue(check.stdout.contains("in sync"), check.stdout)
    }

    func testCheckSkillsStale() throws {
        _ = try CLIRunner.run(["install-skills", "--scope", "project", "--project-dir", tmpDir.path])
        // Tamper the sidecar to simulate a stale install
        let sidecar = tmpDir.appendingPathComponent(".claude/skills/.genesis-skills-version")
        try "0.0.0-stale\n".write(to: sidecar, atomically: true, encoding: .utf8)
        let check = try CLIRunner.run([
            "check-skills", "--scope", "project", "--project-dir", tmpDir.path,
        ])
        XCTAssertEqual(check.exitCode, 2, "stderr: \(check.stderr); stdout: \(check.stdout)")
        XCTAssertTrue(check.stdout.contains("stale"), check.stdout)
        XCTAssertTrue(check.stdout.contains("0.0.0-stale"), "should name the stale version: \(check.stdout)")
    }

    // MARK: - bundle-parse

    func testBundleParseValid() throws {
        let bundle = try fixture("iam-cosmogony-bundle")
        let result = try CLIRunner.run(["bundle-parse", bundle.path])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        // stdout must be pure JSON decodable back to a dict with context == IAMContext
        guard let data = result.stdout.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("bundle-parse stdout is not valid JSON: \(result.stdout.prefix(200))")
        }
        XCTAssertEqual(obj["context"] as? String, "IAMContext")
        XCTAssertNotNil(obj["aggregates"], "parsed JSON must contain aggregates")
    }

    func testBundleParseInvalidExitsOne() throws {
        let bad = tmpDir.appendingPathComponent("bad.json")
        try "{not valid json".write(to: bad, atomically: true, encoding: .utf8)
        let result = try CLIRunner.run(["bundle-parse", bad.path])
        XCTAssertEqual(result.exitCode, 1, "malformed bundle should exit 1; stderr: \(result.stderr)")
    }

    func testBundleParseMissingFileExitsOne() throws {
        let result = try CLIRunner.run(["bundle-parse", "/no/such/bundle.json"])
        XCTAssertEqual(result.exitCode, 1, "missing bundle should exit 1; stderr: \(result.stderr)")
    }
}
