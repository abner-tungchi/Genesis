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

public struct SkillUninstallSummary: Sendable, Equatable {
    public let removed: [String]
    public let skippedModified: [String]   // present but human-edited (contents != bundled) and !force → kept
    public let notPresent: [String]        // bundled skill not installed in the target
    public let failed: [SkillInstallSummary.FailedSkill]

    public init(
        removed: [String],
        skippedModified: [String],
        notPresent: [String],
        failed: [SkillInstallSummary.FailedSkill]
    ) {
        self.removed = removed
        self.skippedModified = skippedModified
        self.notPresent = notPresent
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

    /// Raw content of a bundled skill file (pre-install, pre-`{GenesisVersion}` substitution).
    /// Used by `TestLayoutTests` to drift-guard the test-gen SKILL.md path prose against `TestLayout`'s
    /// templates — i.e. to assert the LLM-skill prose still mirrors the Swift single source.
    public static func bundledSkillFileContents(skill: String, file: String) throws -> String {
        let skillsDir = try bundledSkillsDir()
        let url = skillsDir.appendingPathComponent(skill, isDirectory: true).appendingPathComponent(file)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw GenesisError.skillBundleNotFound(
                reason: "cannot read bundled Templates/skills/\(skill)/\(file): \(error.localizedDescription)"
            )
        }
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

    /// Removes each bundled skill from `targetSkillsDir`. SAFETY (convention over configuration): a skill whose
    /// on-disk contents differ from the bundled version (i.e. human-edited) is KEPT and reported in
    /// `skippedModified` unless `force` is set — uninstall never silently destroys human work. A symlinked /
    /// type-confused entry is refused (recorded in `failed`, never deleted). Best-effort: one skill's failure
    /// does not abort the rest. A non-existent target means nothing is installed (all `notPresent`).
    public static func uninstall(from targetSkillsDir: URL, force: Bool) throws -> SkillUninstallSummary {
        let names = try bundledSkillNames()
        let skillsDir = try bundledSkillsDir()

        var rootIsDir: ObjCBool = false
        let rootExists = FileManager.default.fileExists(atPath: targetSkillsDir.path, isDirectory: &rootIsDir)
        if rootExists {
            let rootIsSymlink = (try? targetSkillsDir.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink == true
            if rootIsSymlink || !rootIsDir.boolValue {
                throw GenesisError.fileSystemFailed(
                    operation: "validate target skills dir",
                    underlying: "\(targetSkillsDir.path) is a symlink or not a directory"
                )
            }
        } else {
            // Nothing installed — every bundled skill is simply not present.
            return SkillUninstallSummary(removed: [], skippedModified: [], notPresent: names, failed: [])
        }

        var removed: [String] = []
        var skippedModified: [String] = []
        var notPresent: [String] = []
        var failed: [SkillInstallSummary.FailedSkill] = []

        for name in names {
            let src = skillsDir.appendingPathComponent(name, isDirectory: true)
            let dest = targetSkillsDir.appendingPathComponent(name, isDirectory: true)

            var destIsDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: dest.path, isDirectory: &destIsDir)
            if !exists {
                notPresent.append(name)
                continue
            }
            let destIsSymlink = (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink == true
            if destIsSymlink || !destIsDir.boolValue {
                failed.append(.init(
                    skill: name,
                    reason: "installed entry is a symlink or not a directory; remove it manually"
                ))
                continue
            }

            // Modification guard: only auto-remove a skill whose contents still match the bundled version.
            let unmodified = (try? directoriesHaveEqualContents(src, dest)) ?? false
            if !unmodified && !force {
                skippedModified.append(name)
                continue
            }
            do {
                try FileManager.default.removeItem(at: dest)
                removed.append(name)
            } catch {
                failed.append(.init(skill: name, reason: error.localizedDescription))
            }
        }

        return SkillUninstallSummary(
            removed: removed,
            skippedModified: skippedModified,
            notPresent: notPresent,
            failed: failed
        )
    }

    /// True iff `a` and `b` directory trees contain exactly the same set of regular files with byte-identical
    /// contents (symlinks are ignored for membership; a regular-vs-symlink mismatch surfaces as a differing
    /// file set → not equal). Used to detect whether an installed skill was human-edited before an unforced
    /// uninstall is allowed to delete it. Fails CLOSED for uninstall: any divergence (or read error) → not equal
    /// → the skill is kept unless --force.
    static func directoriesHaveEqualContents(_ a: URL, _ b: URL) throws -> Bool {
        let af = relativeRegularFiles(under: a)
        let bf = relativeRegularFiles(under: b)
        guard Set(af.keys) == Set(bf.keys) else { return false }
        for (rel, aData) in af {
            guard let bData = bf[rel], aData == bData else { return false }
        }
        return true
    }

    /// Maps each regular (non-symlink) file under `root` to its bytes, keyed by path relative to `root`.
    private static func relativeRegularFiles(under root: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let basePath = root.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return out }
        for case let url as URL in e {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard vals?.isRegularFile == true, vals?.isSymbolicLink != true else { continue }
            var rel = url.standardizedFileURL.path
            if rel.hasPrefix(basePath) { rel.removeFirst(basePath.count) }
            while rel.hasPrefix("/") { rel.removeFirst() }
            out[rel] = (try? Data(contentsOf: url)) ?? Data()
        }
        return out
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
