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
            ["api", "bundle-plan", "domain-fill", "event-storming", "presenter", "presenter-fill", "readmodel", "readmodel-mutation", "strict-review", "test-gen", "usecase", "write-ddd-spec"]
        )
    }

    func testInstallIntoEmptyDir() throws {
        let target = tmpDir.appendingPathComponent("skills", isDirectory: true)
        let summary = try SkillInstaller.install(into: target, force: false)
        XCTAssertEqual(summary.installed.count, 12)  // Phase 1.w added domain-fill (was 11 after test-gen)
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
        XCTAssertEqual(summary.installed.count, 11)  // Phase 1.w: 12 total - 1 skipped (usecase)
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

    // MARK: - uninstall

    func testUninstallRemovesUnmodified() throws {
        let target = tmpDir.appendingPathComponent("skills", isDirectory: true)
        let installed = try SkillInstaller.install(into: target, force: false)
        XCTAssertEqual(installed.installed.count, 12)

        let summary = try SkillInstaller.uninstall(from: target, force: false)
        XCTAssertEqual(summary.removed.count, 12, "freshly-installed (unmodified) skills must all be removed")
        XCTAssertTrue(summary.skippedModified.isEmpty)
        XCTAssertTrue(summary.notPresent.isEmpty)
        XCTAssertTrue(summary.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("usecase").path))
    }

    func testUninstallKeepsHumanEditedSkill() throws {
        let target = tmpDir.appendingPathComponent("skills", isDirectory: true)
        _ = try SkillInstaller.install(into: target, force: false)
        // Human-edit one installed skill's SKILL.md.
        let edited = target.appendingPathComponent("usecase/SKILL.md")
        let original = try String(contentsOf: edited, encoding: .utf8)
        try (original + "\n<!-- human edit -->\n").write(to: edited, atomically: true, encoding: .utf8)

        let summary = try SkillInstaller.uninstall(from: target, force: false)
        XCTAssertTrue(summary.skippedModified.contains("usecase"), "human-edited skill must be kept (not silently deleted)")
        XCTAssertFalse(summary.removed.contains("usecase"))
        XCTAssertEqual(summary.removed.count, 11, "the other 11 unmodified skills are removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: edited.path), "kept skill's file must still exist")
    }

    func testUninstallForceRemovesHumanEditedSkill() throws {
        let target = tmpDir.appendingPathComponent("skills", isDirectory: true)
        _ = try SkillInstaller.install(into: target, force: false)
        let edited = target.appendingPathComponent("usecase/SKILL.md")
        try "totally different".write(to: edited, atomically: true, encoding: .utf8)

        let summary = try SkillInstaller.uninstall(from: target, force: true)
        XCTAssertTrue(summary.removed.contains("usecase"), "--force removes even human-edited skills")
        XCTAssertTrue(summary.skippedModified.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("usecase").path))
    }

    func testUninstallNothingInstalled() throws {
        let target = tmpDir.appendingPathComponent("never-created-skills", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let summary = try SkillInstaller.uninstall(from: target, force: false)
        XCTAssertEqual(summary.notPresent.count, 12, "no install → every bundled skill is not-present")
        XCTAssertTrue(summary.removed.isEmpty)
        XCTAssertTrue(summary.skippedModified.isEmpty)
        XCTAssertTrue(summary.failed.isEmpty)
    }

    func testUninstallRefusesSymlinkEntry() throws {
        let target = tmpDir.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // Put a symlink named after a bundled skill where its dir would be.
        let realDir = tmpDir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let symlink = target.appendingPathComponent("usecase")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realDir)

        let summary = try SkillInstaller.uninstall(from: target, force: true)
        XCTAssertTrue(summary.failed.contains { $0.skill == "usecase" }, "symlink entry must be refused, not followed/deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: realDir.path), "the symlink target must NOT be deleted")
    }

    func testUninstallRejectsSymlinkRoot() throws {
        let realDir = tmpDir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let symlink = tmpDir.appendingPathComponent("skills-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realDir)

        XCTAssertThrowsError(try SkillInstaller.uninstall(from: symlink, force: false)) { error in
            guard case .fileSystemFailed = error as? GenesisError else {
                return XCTFail("expected fileSystemFailed, got \(error)")
            }
        }
    }
}
