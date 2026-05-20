import Foundation

public enum GenesisError: Error, Equatable, Sendable {
    case bundleNotFound(URL)
    case bundleInvalid(reason: String)
    case outputDirHasConflict(path: URL, conflict: String)
    case gitPreflightFailed(reason: String)
    case swiftPackageResolveFailed(stderr: String)
    case swiftBuildFailed(stderr: String)
    case fileSystemFailed(operation: String, underlying: String)
    case contextNameInvalid(value: String)
    case adapterNotFound(URL)
    case adapterInvalid(reason: String)
    case adapterIncompatible(reason: String)
    case skillBundleNotFound(reason: String)
    case skillInstallFailed(skill: String, underlying: String)
}

extension GenesisError {
    public var exitCode: Int32 {
        switch self {
        case .bundleNotFound, .bundleInvalid, .contextNameInvalid, .outputDirHasConflict,
             .adapterNotFound, .adapterInvalid, .adapterIncompatible:
            return 1
        case .fileSystemFailed, .swiftPackageResolveFailed, .swiftBuildFailed,
             .skillBundleNotFound, .skillInstallFailed:
            return 2
        case .gitPreflightFailed:
            return 3
        }
    }

    public var userMessage: String {
        switch self {
        case .bundleNotFound(let url):
            return "bundle file does not exist: \(url.path)"
        case .bundleInvalid(let reason):
            return "bundle is invalid: \(reason)"
        case .outputDirHasConflict(let path, let conflict):
            return "output directory '\(path.path)' already contains \(conflict)"
        case .gitPreflightFailed(let reason):
            return "git pre-flight failed: \(reason)"
        case .swiftPackageResolveFailed(let stderr):
            let preview = String(stderr.prefix(500))
            return "swift package resolve failed:\n\(preview)"
        case .swiftBuildFailed(let stderr):
            // Show the tail (where the actual error lines live), not the head
            // (which is mostly dependency-fetch chatter).
            let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
            let lastN = lines.suffix(40).joined(separator: "\n")
            return "swift build failed (last 40 lines):\n\(lastN)"
        case .fileSystemFailed(let operation, let underlying):
            return "filesystem operation '\(operation)' failed: \(underlying)"
        case .contextNameInvalid(let value):
            return "ContextName must be a PascalCase identifier matching ^[A-Z][A-Za-z0-9]*$; got '\(value)'"
        case .adapterNotFound(let url):
            return "adapter file does not exist: \(url.path)"
        case .adapterInvalid(let reason):
            return "adapter is invalid: \(reason)"
        case .adapterIncompatible(let reason):
            return "adapter is incompatible: \(reason)"
        case .skillBundleNotFound(let reason):
            return "bundled skills not found: \(reason)"
        case .skillInstallFailed(let skill, let underlying):
            return "failed to install skill '\(skill)': \(underlying)"
        }
    }
}
