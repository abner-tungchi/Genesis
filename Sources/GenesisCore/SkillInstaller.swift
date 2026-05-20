import Foundation

public struct SkillInstallSummary: Sendable, Equatable {
    public let installed: [String]
    public let skipped: [String]
    public let overwritten: [String]
    public let failed: [FailedSkill]

    public struct FailedSkill: Sendable, Equatable {
        public let skill: String
        public let reason: String

        public init(skill: String, reason: String) {
            self.skill = skill
            self.reason = reason
        }
    }

    public init(
        installed: [String],
        skipped: [String],
        overwritten: [String],
        failed: [FailedSkill]
    ) {
        self.installed = installed
        self.skipped = skipped
        self.overwritten = overwritten
        self.failed = failed
    }
}

public enum SkillInstaller {
    /// Lists the skill bundle names shipped inside Genesis's resource bundle.
    /// Each valid skill must be a non-symlink directory containing a `SKILL.md`.
    public static func bundledSkillNames() throws -> [String] {
        let skillsDir = try bundledSkillsDir()
        let entries = try FileManager.default.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let validSkills = entries.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return false }
            let skillMd = url.appendingPathComponent("SKILL.md")
            return FileManager.default.fileExists(atPath: skillMd.path)
        }
        if validSkills.isEmpty {
            throw GenesisError.skillBundleNotFound(
                reason: "Templates/skills contains no valid skill directories "
                    + "(each must be a non-symlink dir with SKILL.md)"
            )
        }
        return validSkills.map { $0.lastPathComponent }.sorted()
    }

    /// Installs each bundled skill into `targetSkillsDir`. Best-effort: a failed skill
    /// is recorded in `summary.failed` and does not abort the remaining skills.
    public static func install(into targetSkillsDir: URL, force: Bool) throws -> SkillInstallSummary {
        let names = try bundledSkillNames()
        let skillsDir = try bundledSkillsDir()

        // Reject symlinked / non-directory target root before any mutation.
        var rootIsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: targetSkillsDir.path, isDirectory: &rootIsDir) {
            let rootIsSymlink = (try? targetSkillsDir.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink == true
            if rootIsSymlink || !rootIsDir.boolValue {
                throw GenesisError.fileSystemFailed(
                    operation: "validate target skills dir",
                    underlying: "\(targetSkillsDir.path) is a symlink or not a directory"
                )
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: targetSkillsDir, withIntermediateDirectories: true)
            } catch {
                throw GenesisError.fileSystemFailed(
                    operation: "create skills dir",
                    underlying: error.localizedDescription
                )
            }
        }

        var installed: [String] = []
        var skipped: [String] = []
        var overwritten: [String] = []
        var failed: [SkillInstallSummary.FailedSkill] = []

        for name in names {
            let src = skillsDir.appendingPathComponent(name, isDirectory: true)
            let dest = targetSkillsDir.appendingPathComponent(name, isDirectory: true)

            var destIsDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: dest.path, isDirectory: &destIsDir)
            let destIsSymlink = (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink == true

            if exists && (destIsSymlink || !destIsDir.boolValue) {
                failed.append(.init(
                    skill: name,
                    reason: "existing entry is a symlink or not a directory; remove it manually"
                ))
                continue
            }
            if exists && !force {
                skipped.append(name)
                continue
            }
            do {
                if exists {  // && force && real dir
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
                if exists {
                    overwritten.append(name)
                } else {
                    installed.append(name)
                }
            } catch {
                failed.append(.init(skill: name, reason: error.localizedDescription))
            }
        }

        return SkillInstallSummary(
            installed: installed,
            skipped: skipped,
            overwritten: overwritten,
            failed: failed
        )
    }

    private static func bundledSkillsDir() throws -> URL {
        guard let resourceRoot = Bundle.module.resourceURL else {
            throw GenesisError.skillBundleNotFound(reason: "Bundle.module has no resourceURL")
        }
        let skillsDir = resourceRoot.appendingPathComponent("Templates/skills", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: skillsDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw GenesisError.skillBundleNotFound(
                reason: "bundled Templates/skills directory not found at \(skillsDir.path)"
            )
        }
        return skillsDir
    }
}
