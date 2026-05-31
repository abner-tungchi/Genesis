import ArgumentParser
import Foundation
import GenesisCore

struct CheckSkillsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-skills",
        abstract: "Check whether installed skills are in sync with the current genesis binary."
    )

    @Option(name: .customLong("scope"), help: "user (default) or project.")
    var scope: InstallSkillsCommand.ScopeOption = .user

    @Option(name: .customLong("project-dir"), help: "Project root (only for --scope project; default: cwd).")
    var projectDir: String?

    func run() async throws {
        let targetDir = try SkillTargetResolver.resolveTargetDir(scope: scope, projectDir: projectDir)
        let sidecar = targetDir.appendingPathComponent(".genesis-skills-version", isDirectory: false)

        guard let raw = try? String(contentsOf: sidecar, encoding: .utf8) else {
            print("⚠ skills not installed (no .genesis-skills-version found at \(sidecar.path)); run 'genesis install-skills'")
            genesisExit(2)
            return
        }

        let installed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = GenesisCoreVersion.current

        if installed == current {
            print("✓ skills in sync (version \(current))")
            return
        }

        print("⚠ skills stale: installed \(installed) vs binary \(current); run 'genesis install-skills --force'")
        genesisExit(2)
    }
}
