import Foundation

/// Phase 1.u.1: classify a `swift build` failure as "only blocked by GENESIS-TODO #error domain holes"
/// (an intended, fill-me-later state) vs a real codegen breakage (which must roll back the generation).
///
/// Conservative by design (Codex audit HIGH): it does NOT trust an stderr substring. Every compiler
/// error diagnostic must be the exact `file:line:col: error: GENESIS-TODO:` shape AND the referenced
/// source line must literally be a `#error("GENESIS-TODO` directive (cross-checked against the file on
/// disk — defeats string-injection spoofs via bundle-derived names). Any other failure signal
/// (plain `error:`, `ld: error:`, `link command failed`, launch/timeout text, or a source line that is
/// not a real `#error`) makes it return `false` → roll back. A broken project surviving is far worse
/// than one extra rollback, so anything unrecognized rolls back.
public enum BuildFailureClassifier {

    public static func buildFailureIsOnlyDomainHoles(stderr: String, projectRoot: URL) -> Bool {
        // Linker / driver failures are never domain holes.
        if stderr.contains("ld: ") || stderr.contains("link command failed") {
            return false
        }

        // Every line that looks like a compiler error must be a cross-checked GENESIS-TODO #error.
        var verifiedHoleCount = 0
        for rawLine in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // Only diagnostic "error:" lines matter (skip warnings/notes/"N errors generated").
            guard line.contains("error:") else { continue }
            // "N error(s) generated." is a summary, not a diagnostic.
            if line.range(of: #"^\d+ errors? generated\.?$"#, options: .regularExpression) != nil { continue }

            guard let hole = parseGenesisTodoErrorLine(line),
                  sourceLineIsErrorDirective(file: hole.file, line: hole.line, projectRoot: projectRoot)
            else {
                return false  // a real / unrecognized error → roll back
            }
            verifiedHoleCount += 1
        }

        return verifiedHoleCount > 0
    }

    /// Parse `<path>.swift:<line>:<col>: error: GENESIS-TODO: ...` → (file, line). nil if not that exact shape.
    private static func parseGenesisTodoErrorLine(_ line: String) -> (file: String, line: Int)? {
        guard let match = line.range(
            of: #"^(.+\.swift):(\d+):\d+: error: GENESIS-TODO:"#,
            options: .regularExpression
        ), match.lowerBound == line.startIndex else {
            return nil
        }
        // Extract path + line number from the prefix before ": error:".
        guard let errorMarker = line.range(of: ": error: GENESIS-TODO:") else { return nil }
        let prefix = String(line[line.startIndex..<errorMarker.lowerBound])  // "<path>:<line>:<col>"
        let parts = prefix.split(separator: ":")
        guard parts.count >= 3, let lineNo = Int(parts[parts.count - 2]) else { return nil }
        let file = parts[0..<(parts.count - 2)].joined(separator: ":")
        return (file: file, line: lineNo)
    }

    /// Cross-check: the source at `file:line` must literally contain `#error("GENESIS-TODO`.
    /// `file` may be absolute or relative to `projectRoot`. Returns false if unreadable / not an #error.
    private static func sourceLineIsErrorDirective(file: String, line: Int, projectRoot: URL) -> Bool {
        let fileURL: URL = file.hasPrefix("/")
            ? URL(fileURLWithPath: file)
            : projectRoot.appendingPathComponent(file)
        guard line >= 1, let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return false
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard line <= lines.count else { return false }
        return String(lines[line - 1]).contains(##"#error("GENESIS-TODO"##)
    }
}
