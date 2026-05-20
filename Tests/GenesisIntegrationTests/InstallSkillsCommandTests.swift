import XCTest

final class InstallSkillsCommandTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallSkillsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private let expectedSkills = ["api", "event-storming", "readmodel", "strict-review", "usecase", "write-ddd-spec"]

    func testInstallProjectScope() throws {
        let result = try CLIRunner.run([
            "install-skills", "--scope", "project", "--project-dir", tmpDir.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        for skill in expectedSkills {
            let skillDir = tmpDir.appendingPathComponent(".claude/skills/\(skill)")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: skillDir.appendingPathComponent("SKILL.md").path),
                "missing skill: \(skill)"
            )
        }
    }

    func testInstallProjectScopeIdempotentSkip() throws {
        _ = try CLIRunner.run(["install-skills", "--scope", "project", "--project-dir", tmpDir.path])
        let second = try CLIRunner.run(["install-skills", "--scope", "project", "--project-dir", tmpDir.path])
        XCTAssertEqual(second.exitCode, 0, "stderr: \(second.stderr)")
        XCTAssertTrue(second.stdout.contains("skipped"), second.stdout)
    }

    func testInstallProjectScopeForce() throws {
        _ = try CLIRunner.run(["install-skills", "--scope", "project", "--project-dir", tmpDir.path])
        let forced = try CLIRunner.run([
            "install-skills", "--scope", "project", "--project-dir", tmpDir.path, "--force",
        ])
        XCTAssertEqual(forced.exitCode, 0, "stderr: \(forced.stderr)")
        XCTAssertTrue(forced.stdout.contains("overwritten"), forced.stdout)
    }

    func testInvalidProjectDir() throws {
        let result = try CLIRunner.run([
            "install-skills", "--scope", "project", "--project-dir", "/no/such/genesis/path",
        ])
        XCTAssertEqual(result.exitCode, 1, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("does not exist") || result.stderr.contains("not a directory"))
    }

    func testUserScopeWithProjectDirRejected() throws {
        let result = try CLIRunner.run([
            "install-skills", "--scope", "user", "--project-dir", tmpDir.path,
        ])
        XCTAssertEqual(result.exitCode, 1, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("only valid with --scope project"))
    }

    func testUserScopeWithHomeOverride() throws {
        let fakeHome = tmpDir.appendingPathComponent("fakehome", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = fakeHome.path

        let result = try CLIRunner.run(["install-skills", "--scope", "user"], environment: env)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        for skill in expectedSkills {
            let skillDir = fakeHome.appendingPathComponent(".claude/skills/\(skill)")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: skillDir.appendingPathComponent("SKILL.md").path),
                "missing skill in fake home: \(skill)"
            )
        }
    }
}
