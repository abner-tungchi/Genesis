import ArgumentParser
import Foundation
import GenesisCore

struct UninstallSkillsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall-skills",
        abstract: "Remove bundled Claude Code skills from ~/.claude/skills or a project "
            + "(keeps human-edited skills unless --force)."
    )

    @Option(name: .customLong("scope"), help: "user (default) or project.")
    var scope: InstallSkillsCommand.ScopeOption = .user

    @Option(name: .customLong("project-dir"), help: "Project root (only for --scope project; default: cwd).")
    var projectDir: String?

    @Flag(name: .customLong("force"), help: "Also remove skills whose contents differ from the bundled version (human-edited).")
    var force: Bool = false

    func run() async throws {
        // Phase 1: resolve target dir (shared with install/check-skills; also validates scope/project-dir)
        let targetDir = try SkillTargetResolver.resolveTargetDir(scope: scope, projectDir: projectDir)

        // Phase 2: uninstall (content-guarded: keeps human-edited skills unless --force)
        let summary = try SkillInstaller.uninstall(from: targetDir, force: force)

        // Phase 3: report (decide success/failure first, then pick banner)
        let hasFailure = !summary.failed.isEmpty
        var lines: [String] = []
        if hasFailure {
            lines.append(
                "⚠️ Genesis: removed \(summary.removed.count), kept-modified \(summary.skippedModified.count), "
                + "not-present \(summary.notPresent.count), FAILED \(summary.failed.count) skill(s) from \(targetDir.path)"
            )
        } else {
            lines.append(
                "✓ Genesis: removed \(summary.removed.count), kept-modified \(summary.skippedModified.count), "
                + "not-present \(summary.notPresent.count) skill(s) from \(targetDir.path)"
            )
        }
        if !summary.removed.isEmpty {
            lines.append("  removed:       \(summary.removed.joined(separator: ", "))")
        }
        if !summary.skippedModified.isEmpty {
            lines.append(
                "  kept-modified: \(summary.skippedModified.joined(separator: ", "))"
                + "  (human-edited; pass --force to remove)"
            )
        }
        if hasFailure {
            lines.append("  failed:        \(summary.failed.map { $0.skill }.joined(separator: ", "))  (see stderr)")
        }
        print(lines.joined(separator: "\n"))

        // Phase 3.5: drop the version sidecar only on a CLEAN sweep — no genesis-managed skill remains
        // (nothing kept-modified, nothing failed). If skills remain, the sidecar stays meaningful for check-skills.
        // Non-critical path — a removal failure warns but does not change the exit code.
        if summary.skippedModified.isEmpty && summary.failed.isEmpty {
            let sidecar = targetDir.appendingPathComponent(".genesis-skills-version", isDirectory: false)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                do {
                    try FileManager.default.removeItem(at: sidecar)
                } catch {
                    FileHandle.standardError.write(Data(
                        "⚠ failed to remove version sidecar at \(sidecar.path): \(error.localizedDescription)\n".utf8
                    ))
                }
            }
        }

        if hasFailure {
            for failure in summary.failed {
                FileHandle.standardError.write(Data(
                    "✗ failed to remove '\(failure.skill)': \(failure.reason)\n".utf8
                ))
            }
            genesisExit(2)
        }
    }
}
