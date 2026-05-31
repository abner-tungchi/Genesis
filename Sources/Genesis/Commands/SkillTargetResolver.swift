import Foundation
import GenesisCore

/// Phase 1.q: shared target-dir resolution for install-skills / check-skills.
/// Uses $HOME (overridable for tests), NOT homeDirectoryForCurrentUser which
/// ignores $HOME overrides on macOS.
enum SkillTargetResolver {
    static func resolveTargetDir(
        scope: InstallSkillsCommand.ScopeOption,
        projectDir: String?
    ) throws -> URL {
        switch scope {
        case .user:
            if projectDir != nil {
                throw GenesisError.bundleInvalid(reason: "--project-dir is only valid with --scope project")
            }
            guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
                throw GenesisError.bundleInvalid(reason: "$HOME is not set; cannot resolve user scope")
            }
            return URL(fileURLWithPath: home).appendingPathComponent(".claude/skills", isDirectory: true)
        case .project:
            let root = URL(fileURLWithPath: projectDir ?? FileManager.default.currentDirectoryPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                throw GenesisError.bundleInvalid(
                    reason: "--project-dir does not exist or is not a directory: \(root.path)"
                )
            }
            return root.appendingPathComponent(".claude/skills", isDirectory: true)
        }
    }
}
