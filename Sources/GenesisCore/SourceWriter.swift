import Foundation

public final class SourceWriter {
    public let root: URL

    private var planned: [(URL, String)] = []
    private var writtenFiles: [URL] = []
    private var createdDirs: [URL] = []

    public init(root: URL) {
        self.root = root
    }

    public var plannedCount: Int { planned.count }
    public var writtenFileCount: Int { writtenFiles.count }

    public func plan(relativePath: String, content: String) throws {
        let url = root.appendingPathComponent(relativePath)
        // Phase 1.f: same-run duplicate planned path detection. If a previous renderer already planned
        // this path (e.g. infra filename collides with user customType name), surface immediately rather
        // than silently overwriting in commit().
        if planned.contains(where: { $0.0 == url }) {
            throw GenesisError.outputDirHasConflict(
                path: root,
                conflict: "duplicate planned path: \(relativePath) (check adapter customTypes for collision with Phase 1.f infra names: ApplicationService / ContextError / Iso8601 / InvalidDecimalStringError / ProjectionReadInconsistency / String+IsBlank / String+PascalCase / String+StrippingPrefix / README)"
            )
        }
        planned.append((url, content))
    }

    /// Throws if any planned file already exists under root. Single fs-conflict gate
    /// for all Phase 1.c write surfaces; call BEFORE commit().
    public func checkNoConflicts() throws {
        for (url, _) in planned {
            if FileManager.default.fileExists(atPath: url.path) {
                let relativePath = url.path.hasPrefix(root.path)
                    ? String(url.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
                    : url.path
                throw GenesisError.outputDirHasConflict(path: root, conflict: relativePath)
            }
        }
    }

    public func commit() throws {
        for (url, content) in planned {
            recordCreatedParents(for: url)
            let parent = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                rollback()
                throw GenesisError.fileSystemFailed(
                    operation: "create directory \(parent.path)",
                    underlying: error.localizedDescription
                )
            }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                writtenFiles.append(url)
            } catch {
                rollback()
                throw GenesisError.fileSystemFailed(
                    operation: "write file \(url.path)",
                    underlying: error.localizedDescription
                )
            }
        }
    }

    public func rollback() {
        for url in writtenFiles.reversed() {
            try? FileManager.default.removeItem(at: url)
        }
        for dir in createdDirs.reversed() {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if contents.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        writtenFiles.removeAll()
        createdDirs.removeAll()
    }

    private func recordCreatedParents(for fileURL: URL) {
        var ancestors: [URL] = []
        var cursor = fileURL.deletingLastPathComponent()
        let rootPath = root.standardizedFileURL.path
        while cursor.path.hasPrefix(rootPath), cursor.path != "/" {
            if !FileManager.default.fileExists(atPath: cursor.path) {
                ancestors.append(cursor)
            } else {
                break
            }
            let next = cursor.deletingLastPathComponent()
            if next.path == cursor.path { break }
            cursor = next
        }
        for dir in ancestors.reversed() {
            if !createdDirs.contains(where: { $0.standardizedFileURL == dir.standardizedFileURL }) {
                createdDirs.append(dir)
            }
        }
    }
}
