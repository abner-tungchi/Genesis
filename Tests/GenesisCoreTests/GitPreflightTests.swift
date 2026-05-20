import XCTest
@testable import GenesisCore

final class GitPreflightTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitPreflightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func runGit(_ args: [String], cwd: URL? = nil) -> ProcessResult {
        ProcessRunner.run(executable: "git", args: args, cwd: cwd ?? tmpDir)
    }

    func testCleanRepo() throws {
        runGit(["init", "-q"])
        // Make at least one commit so the working tree is not "no commits yet" + clean.
        runGit(["config", "user.email", "test@example.com"])
        runGit(["config", "user.name", "Test User"])
        runGit(["commit", "--allow-empty", "-m", "init", "-q"])

        XCTAssertNoThrow(try GitPreflight.check(at: tmpDir, skip: false))
    }

    func testDirtyRepo() throws {
        runGit(["init", "-q"])
        runGit(["config", "user.email", "test@example.com"])
        runGit(["config", "user.name", "Test User"])
        runGit(["commit", "--allow-empty", "-m", "init", "-q"])

        let stray = tmpDir.appendingPathComponent("stray.txt")
        try "dirty".write(to: stray, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try GitPreflight.check(at: tmpDir, skip: false)) { error in
            guard case .gitPreflightFailed(let reason) = error as? GenesisError else {
                return XCTFail("expected gitPreflightFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("uncommitted"), "reason: \(reason)")
        }
    }

    func testNonRepo() {
        XCTAssertThrowsError(try GitPreflight.check(at: tmpDir, skip: false)) { error in
            guard case .gitPreflightFailed(let reason) = error as? GenesisError else {
                return XCTFail("expected gitPreflightFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("not inside git work tree"), "reason: \(reason)")
        }
    }

    func testSkipFlag() throws {
        // Dirty repo + skip: true → must not throw.
        runGit(["init", "-q"])
        let stray = tmpDir.appendingPathComponent("stray.txt")
        try "dirty".write(to: stray, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try GitPreflight.check(at: tmpDir, skip: true))
    }

    func testPathNotExist() {
        let bogus = tmpDir.appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertThrowsError(try GitPreflight.check(at: bogus, skip: false)) { error in
            guard case .gitPreflightFailed(let reason) = error as? GenesisError else {
                return XCTFail("expected gitPreflightFailed, got \(error)")
            }
            XCTAssertTrue(
                reason.contains("does not exist") || reason.contains("not a directory"),
                "reason: \(reason)"
            )
        }
    }
}
