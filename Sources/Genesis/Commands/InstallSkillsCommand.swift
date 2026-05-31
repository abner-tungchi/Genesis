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
        // Phase 1: resolve target dir (shared with check-skills; also validates scope/project-dir)
        let targetDir = try SkillTargetResolver.resolveTargetDir(scope: scope, projectDir: projectDir)

        // Phase 2: install
        let summary = try SkillInstaller.install(into: targetDir, force: force)

        // Phase 2.5 (Phase 1.q): stamp the version sidecar so `check-skills` can detect drift.
        // Non-critical path — a write failure warns but does not change install exit code.
        let sidecar = targetDir.appendingPathComponent(".genesis-skills-version", isDirectory: false)
        do {
            try "\(GenesisCoreVersion.current)\n".write(to: sidecar, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data(
                "⚠ failed to write version sidecar at \(sidecar.path): \(error.localizedDescription)\n".utf8
            ))
        }

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

        // Phase 1.q (D13): on user scope, warn about project-local Genesis skills that would
        // SHADOW the global install. Advisory only — never auto-delete, never affect exit code.
        if scope == .user {
            scanProjectLocalSkills()
        }

        if hasFailure {
            for failure in summary.failed {
                FileHandle.standardError.write(Data(
                    "✗ failed to install '\(failure.skill)': \(failure.reason)\n".utf8
                ))
            }
            genesisExit(2)
        }
    }

    /// Phase 1.q (D13): scan `$HOME/JiaBao/` for project-local Genesis skills that shadow
    /// the global install. Best-effort — any FS error silently skips (does not abort install).
    private func scanProjectLocalSkills() {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return }
        guard let bundledNames = try? SkillInstaller.bundledSkillNames(), !bundledNames.isEmpty else { return }
        let bundledSet = Set(bundledNames)
        let searchRoot = URL(fileURLWithPath: home).appendingPathComponent("JiaBao", isDirectory: true)
        guard FileManager.default.fileExists(atPath: searchRoot.path) else { return }
        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Collect project-local skill dirs grouped by their `.claude/skills` parent.
        var hitsByParent: [String: [String]] = [:]
        for case let url as URL in enumerator {
            // Match `<project>/.claude/skills/<skillName>` where skillName is a bundled Genesis skill.
            guard url.lastPathComponent == "skills" else { continue }
            let parent = url.deletingLastPathComponent()  // .../.claude
            guard parent.lastPathComponent == ".claude" else { continue }
            // Don't recurse into this skills dir's children via the enumerator's own walk;
            // instead list its immediate subdirs to find Genesis skill names.
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            ) else { continue }
            let found = entries
                .map { $0.lastPathComponent }
                .filter { bundledSet.contains($0) }
                .sorted()
            if !found.isEmpty {
                hitsByParent[url.path] = found
            }
        }

        for (skillsPath, names) in hitsByParent.sorted(by: { $0.key < $1.key }) {
            let projectRoot = URL(fileURLWithPath: skillsPath)
                .deletingLastPathComponent()  // .claude
                .deletingLastPathComponent()  // project root
                .path
            FileHandle.standardError.write(Data((
                "⚠ Found project-local Genesis skills at \(skillsPath).\n"
                + "  These will SHADOW global skills. Consider removing manually:\n"
                + "    rm -rf \(projectRoot)/.claude/skills/{\(names.joined(separator: ","))}\n"
            ).utf8))
        }
    }
}
