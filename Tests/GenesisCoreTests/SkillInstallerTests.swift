import XCTest
@testable import GenesisCore

final class SkillInstallerTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testBundledSkillNamesReturnsSixSkills() throws {
        let names = try SkillInstaller.bundledSkillNames()
        XCTAssertEqual(
            Set(names),
            ["api", "bundle-plan", "event-storming", "presenter", "presenter-fill", "readmodel", "readmodel-mutation", "strict-review", "usecase", "write-ddd-spec"]
        )
    }

    func testInstallIntoEmptyDir() throws {
        let target = tmpDir.appendingPathComponent("skills", isDirectory: true)
        let summary = try SkillInstaller.install(into: target, force: false)
        XCTAssertEqual(summary.installed.count, 10)  // Phase 1.r added bundle-plan
        XCTAssertTrue(summary.skipped.isEmpty)
        XCTAssertTrue(summary.overwritten.isEmpty)
        XCTAssertTrue(summary.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("usecase/SKILL.md").path))
    }

    func testInstallSkipsExisting() throws {
        let target = tmpDir.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("usecase"), withIntermediateDirectories: true
        )
        let summary = try SkillInstaller.install(into: target, force: false)
        XCTAssertTrue(summary.skipped.contains("usecase"))
        XCTAssertFalse(summary.installed.contains("usecase"))
        XCTAssertEqual(summary.installed.count, 9)  // Phase 1.r: 10 total - 1 skipped (usecase)
    }

    func testInstallForceOverwrites() throws {
        let target = tmpDir.appendingPathComponent("skills", isDirectory: true)
        let usecaseDir = target.appendingPathComponent("usecase", isDirectory: true)
        try FileManager.default.createDirectory(at: usecaseDir, withIntermediateDirectories: true)
        let marker = usecaseDir.appendingPathComponent("marker.txt")
        try "stale".write(to: marker, atomically: true, encoding: .utf8)

        let summary = try SkillInstaller.install(into: target, force: true)
        XCTAssertTrue(summary.overwritten.contains("usecase"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "force should fully replace the dir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: usecaseDir.appendingPathComponent("SKILL.md").path))
    }

    func testInstallCreatesTargetDirWhenMissing() throws {
        let target = tmpDir.appendingPathComponent("nested/deep/skills", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        _ = try SkillInstaller.install(into: target, force: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testInstallRejectsSymlinkRoot() throws {
        let realDir = tmpDir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let symlink = tmpDir.appendingPathComponent("skills-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realDir)

        XCTAssertThrowsError(try SkillInstaller.install(into: symlink, force: false)) { error in
            guard case .fileSystemFailed = error as? GenesisError else {
                return XCTFail("expected fileSystemFailed, got \(error)")
            }
        }
    }

    func testInstallRejectsTypeConfusedEntry() throws {
        let target = tmpDir.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // Put a *file* named "usecase" where a skill dir would go.
        let fileEntry = target.appendingPathComponent("usecase")
        try "i am a file".write(to: fileEntry, atomically: true, encoding: .utf8)

        let summary = try SkillInstaller.install(into: target, force: true)
        XCTAssertTrue(summary.failed.contains { $0.skill == "usecase" })
        // The file must NOT have been deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileEntry.path))
        let content = try String(contentsOf: fileEntry, encoding: .utf8)
        XCTAssertEqual(content, "i am a file")
    }
}
