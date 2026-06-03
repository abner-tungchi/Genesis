import Foundation

/// Phase 1.y: the structural honesty gate that replaces #error's compile-time enforcement.
/// `genesis verify` (run in a generated project root) checks two things WITHOUT needing the bundle:
///  1. no GenesisTODO.notImplemented marker remains in Sources/ (unfilled domain holes).
///  2. every aggregate invariant errorCode (read from <A>Error.swift's enum cases — the bundle is not
///     copied into the generated tree) has ≥1 ENABLED (non-.disabled) test referencing it. This is the
///     non-circular backstop for the no-op ensureInvariant: it checks the STRUCTURAL fact that an enabled
///     invariant test exists, NOT that test-gen synthesized the invariant-tripping state (which it cannot).
///
/// Detection is comment-and-disabled-aware (a naive grep would false-positive on test-gen's commented-out
/// `// #expect(error?.error == .<code>)` template). Residual risk (a hand-rolled string-built errorCode, or
/// a `//`-inside-string-literal) is accepted and documented, mirroring BuildFailureClassifier's spoofing stance.
public enum VerifyChecker {

    public struct Hole: Equatable {
        public let file: String
        public let snippet: String
    }

    public struct Result {
        public let remainingMarkers: [Hole]
        public let uncoveredInvariants: [String]   // errorCodes with no enabled test
        public var passed: Bool { remainingMarkers.isEmpty && uncoveredInvariants.isEmpty }
    }

    public static func verify(projectRoot: URL) -> Result {
        let sourcesURL = projectRoot.appendingPathComponent("Sources")
        let testsURL = projectRoot.appendingPathComponent("Tests")

        var markers: [Hole] = []
        var invariantCodes: Set<String> = []

        for url in swiftFiles(in: sourcesURL) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rel = url.path.replacingOccurrences(of: projectRoot.path + "/", with: "")

            // (1) remaining markers — actual calls, not comments, not the enum declaration itself.
            for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                guard line.contains("GenesisTODO.notImplemented") else { continue }
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                markers.append(Hole(file: rel, snippet: line.trimmingCharacters(in: .whitespaces)))
            }

            // (2a) invariant errorCodes — the enum cases in the AGGREGATE error file ONLY.
            // Precise match: the enclosing `<A>Aggregate` dir gives <A>; the invariant error file is exactly
            // `<A>Error.swift` — NOT `<A>QueryError.swift` (read-side, e.g. `case notFound`) nor ApiError files.
            if let aggComp = url.pathComponents.first(where: { $0.hasSuffix("Aggregate") }) {
                let aggName = String(aggComp.dropLast("Aggregate".count))
                if url.lastPathComponent == "\(aggName)Error.swift" {
                    for code in enumCases(in: stripComments(content)) where code != "placeholder" {
                        invariantCodes.insert(code)
                    }
                }
            }
        }

        // (2b) enabled-test coverage: comment-stripped, segmented by @Test, .disabled excluded.
        let enabledRegions = enabledTestRegions(in: testsURL)
        var uncovered: [String] = []
        for code in invariantCodes.sorted() {
            let covered = enabledRegions.contains { referencesCode($0, code) }
            if !covered { uncovered.append(code) }
        }

        return Result(remainingMarkers: markers, uncoveredInvariants: uncovered)
    }

    // MARK: - helpers

    /// Whole-token match for `.<code>` — a substring `contains` would let `.permission` be falsely "covered"
    /// by a test referencing `.permissionDenied` (prefix collision → false-negative that defeats the backstop).
    /// Require `.<code>` NOT followed by an identifier character.
    static func referencesCode(_ region: String, _ code: String) -> Bool {
        let pattern = "\\.\(NSRegularExpression.escapedPattern(for: code))(?![A-Za-z0-9_])"
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return region.contains(".\(code)")
        }
        return re.firstMatch(in: region, range: NSRange(region.startIndex..., in: region)) != nil
    }

    static func swiftFiles(in root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "swift" { out.append(url) }
        return out
    }

    /// Enum case identifiers declared on `case <ident>` lines (single-case form; the renderer emits one per line).
    static func enumCases(in content: String) -> [String] {
        var out: [String] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("case ") else { continue }
            let rest = line.dropFirst("case ".count)
            // take the leading identifier (stop at space, (, :, ,)
            let ident = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !ident.isEmpty { out.append(String(ident)) }
        }
        return out
    }

    /// Strip block comments (/* */) then line comments (// to EOL). Not string-literal aware (documented residual).
    static func stripComments(_ s: String) -> String {
        var t = s
        // block comments (non-greedy)
        if let re = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/") {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        }
        // line comments
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Comment-stripped regions of each `@Test`, keeping only enabled ones (attribute list lacks `.disabled`).
    /// A region spans from one `@Test` to the next (approximate: attributes + body), enough to check
    /// (a) `.disabled` presence and (b) `.<errorCode>` references.
    static func enabledTestRegions(in testsRoot: URL) -> [String] {
        var regions: [String] = []
        for url in swiftFiles(in: testsRoot) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = stripComments(content)
            let parts = stripped.components(separatedBy: "@Test")
            // parts[0] is the preamble before the first @Test; parts[1...] each begin a test region.
            for region in parts.dropFirst() {
                if region.contains(".disabled") { continue }   // disabled trait → not an enabled test
                regions.append(region)
            }
        }
        return regions
    }
}
