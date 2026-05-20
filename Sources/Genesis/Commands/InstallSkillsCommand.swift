import ArgumentParser
import Foundation
import GenesisCore

struct InstallSkillsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-skills",
        abstract: "Install bundled Claude Code skills into ~/.claude/skills or a project."
    )

    enum ScopeOption: String, ExpressibleByArgument {
        case user
        case project
    }

    @Option(name: .customLong("scope"), help: "user (default) or project.")
    var scope: ScopeOption = .user

    @Option(name: .customLong("project-dir"), help: "Project root (only for --scope project; default: cwd).")
    var projectDir: String?

    @Flag(name: .customLong("force"), help: "Overwrite existing same-named skills.")
    var force: Bool = false

    func run() async throws {
        // Phase 0: sanity
        if scope == .user, projectDir != nil {
            throw GenesisError.bundleInvalid(reason: "--project-dir is only valid with --scope project")
        }

        // Phase 1: resolve target dir
        let targetDir: URL
        switch scope {
        case .user:
            // Use $HOME (overridable for tests), NOT homeDirectoryForCurrentUser
            // which ignores $HOME overrides on macOS.
            guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
                throw GenesisError.bundleInvalid(reason: "$HOME is not set; cannot resolve user scope")
            }
            targetDir = URL(fileURLWithPath: home).appendingPathComponent(".claude/skills", isDirectory: true)
        case .project:
            let root = URL(fileURLWithPath: projectDir ?? FileManager.default.currentDirectoryPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                throw GenesisError.bundleInvalid(
                    reason: "--project-dir does not exist or is not a directory: \(root.path)"
                )
            }
            targetDir = root.appendingPathComponent(".claude/skills", isDirectory: true)
        }

        // Phase 2: install
        let summary = try SkillInstaller.install(into: targetDir, force: force)

        // Phase 3: report (decide success/failure first, then pick banner)
        let hasFailure = !summary.failed.isEmpty
        var lines: [String] = []
        if hasFailure {
            lines.append(
                "⚠️ Genesis: installed \(summary.installed.count), skipped \(summary.skipped.count), "
                + "overwritten \(summary.overwritten.count), FAILED \(summary.failed.count) "
                + "skill(s) into \(targetDir.path)"
            )
        } else {
            lines.append(
                "✓ Genesis: installed \(summary.installed.count), skipped \(summary.skipped.count), "
                + "overwritten \(summary.overwritten.count) skill(s) into \(targetDir.path)"
            )
        }
        if !summary.installed.isEmpty {
            lines.append("  installed:   \(summary.installed.joined(separator: ", "))")
        }
        if !summary.skipped.isEmpty {
            lines.append(
                "  skipped:     \(summary.skipped.joined(separator: ", "))"
                + "  (already exist; pass --force to overwrite)"
            )
        }
        if !summary.overwritten.isEmpty {
            lines.append("  overwritten: \(summary.overwritten.joined(separator: ", "))")
        }
        if hasFailure {
            lines.append("  failed:      \(summary.failed.map { $0.skill }.joined(separator: ", "))  (see stderr)")
        }
        print(lines.joined(separator: "\n"))

        if hasFailure {
            for failure in summary.failed {
                FileHandle.standardError.write(Data(
                    "✗ failed to install '\(failure.skill)': \(failure.reason)\n".utf8
                ))
            }
            genesisExit(2)
        }
    }
}
