import Foundation

public enum GitPreflight {
    public static func check(at path: URL, skip: Bool) throws {
        guard !skip else { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue else {
            throw GenesisError.gitPreflightFailed(
                reason: "output path does not exist or is not a directory: \(path.path)"
            )
        }

        let isRepo = ProcessRunner.run(executable: "git", args: ["rev-parse", "--is-inside-work-tree"], cwd: path)
        let trimmed = isRepo.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRepo.exitCode == 0, trimmed == "true" else {
            throw GenesisError.gitPreflightFailed(
                reason: "not inside git work tree at \(path.path); pass --no-git to bypass"
            )
        }

        let status = ProcessRunner.run(executable: "git", args: ["status", "--porcelain", "--", "."], cwd: path)
        guard status.exitCode == 0 else {
            throw GenesisError.gitPreflightFailed(reason: "git status failed: \(status.stderr)")
        }
        if !status.stdout.isEmpty {
            let preview = String(status.stdout.prefix(200))
            throw GenesisError.gitPreflightFailed(
                reason: "uncommitted changes inside \(path.path):\n\(preview)"
            )
        }
    }
}
