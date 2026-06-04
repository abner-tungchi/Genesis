import Foundation

/// Phase 1.y/1.z: the structural honesty gate that replaces #error's compile-time enforcement.
/// `genesis verify` (run in a generated project root) checks three things WITHOUT needing the bundle:
///  1. no GenesisTODO.notImplemented marker remains in Sources/ (unfilled domain holes).
///  2. every aggregate invariant errorCode (read from <A>Error.swift's enum cases — the bundle is not
///     copied into the generated tree) has ≥1 ENABLED (non-.disabled) test referencing it via a LIVE
///     assertion. Non-circular backstop for the no-op ensureInvariant: it checks the STRUCTURAL fact that
///     an enabled invariant test exists, NOT that test-gen synthesized the invariant-tripping state.
///  3. (Phase 1.z FIX-2) no remaining test-side Given hole: an enabled @Test in Tests/ that still calls the
///     `genesisTODO(...)` arrange-thunk (or GenesisTODO.notImplemented) is an unfilled Given — the enabled-red
///     world moved the hole from Sources(#error/.disabled) into Tests/, so the gate follows it.
///
/// Detection is comment-AND-string-literal-aware (Phase 1.z FIX-1) via a single-pass `sanitizeSwift` lexer.
/// A naive grep would (a) false-POSITIVE coverage on test-gen's `genesisTODO("... .<code> ...")` thunk
/// MESSAGE, (b) false-EXCLUDE an enabled test whose thunk message contains the token `.disabled`, (c)
/// false-FLAG a string that merely mentions `genesisTODO(`, or — worse — (d) HIDE a real `genesisTODO(`
/// hole when a triple-quoted / raw string / `//`-inside-a-string earlier in the file desynced a two-pass
/// strip (a DANGEROUS false-GREEN, found by the Phase 1.z impl-verify). `sanitizeSwift` is a single-pass
/// lexer that blanks comment and string-literal CONTENT correctly (line / nested-block comments; normal,
/// multiline `"""`, and raw `#"..."#` strings) — it does not desync, so it is safe in BOTH directions at
/// once (never hides a hole, never false-covers an invariant). Residual: genuinely malformed (non-compiling)
/// Swift is out of scope — it would fail `swift build` first.
public enum VerifyChecker {

    public struct Hole: Equatable {
        public let file: String
        public let snippet: String
    }

    public struct Result {
        public let remainingMarkers: [Hole]
        public let uncoveredInvariants: [String]   // errorCodes with no enabled live-assertion test
        public let remainingTestHoles: [Hole]      // FIX-2: genesisTODO( arrange-thunks left in enabled @Tests
        public var passed: Bool {
            remainingMarkers.isEmpty && uncoveredInvariants.isEmpty && remainingTestHoles.isEmpty
        }
    }

    public static func verify(projectRoot: URL) -> Result {
        let sourcesURL = projectRoot.appendingPathComponent("Sources")
        let testsURL = projectRoot.appendingPathComponent("Tests")

        var markers: [Hole] = []
        var invariantCodes: Set<String> = []

        for url in swiftFiles(in: sourcesURL) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rel = url.path.replacingOccurrences(of: projectRoot.path + "/", with: "")

            // (1) remaining markers — real GenesisTODO.notImplemented CALLS, not comments/strings, not the
            // enum declaration itself. Detect on the sanitized line (comment/string content blanked, so a
            // marker token inside a // /* */ or "string" does not count), report the RAW line so the helpful
            // message survives in the report. sanitizeSwift preserves the line count 1:1; if that ever fails
            // we fall back to a raw scan that only skips //-prefixed lines (fail-CLOSED: over-flag, never hide).
            let rawLines = content.components(separatedBy: "\n")
            let sanLines = sanitizeSwift(content).components(separatedBy: "\n")
            if rawLines.count == sanLines.count {
                for (raw, san) in zip(rawLines, sanLines) where san.contains("GenesisTODO.notImplemented") {
                    markers.append(Hole(file: rel, snippet: raw.trimmingCharacters(in: .whitespaces)))
                }
            } else {
                for raw in rawLines where raw.contains("GenesisTODO.notImplemented") {
                    if raw.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    markers.append(Hole(file: rel, snippet: raw.trimmingCharacters(in: .whitespaces)))
                }
            }

            // (2a) invariant errorCodes — the enum cases in the AGGREGATE error file ONLY.
            // Precise match: the enclosing `<A>Aggregate` dir gives <A>; the invariant error file is exactly
            // `<A>Error.swift` — NOT `<A>QueryError.swift` (read-side, e.g. `case notFound`) nor ApiError files.
            if let aggComp = url.pathComponents.first(where: { $0.hasSuffix("Aggregate") }) {
                let aggName = String(aggComp.dropLast("Aggregate".count))
                if url.lastPathComponent == "\(aggName)Error.swift" {
                    for code in enumCases(in: sanitizeSwift(content)) where code != "placeholder" {
                        invariantCodes.insert(code)
                    }
                }
            }
        }

        // (2b) enabled-test coverage + (3, FIX-2) test-side holes — single-pass-lexer sanitized (comments AND
        // string literals blanked), segmented by @Test, .disabled excluded. Per-file so test holes keep their path.
        var enabledRegions: [String] = []
        var testHoles: [Hole] = []
        for url in swiftFiles(in: testsURL) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rel = url.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
            let sanitized = sanitizeSwift(content)
            let parts = sanitized.components(separatedBy: "@Test")
            // parts[0] is the preamble before the first @Test (also where the genesisTODO<T> helper definition
            // sits — not an @Test region, so never scanned for holes); parts[1...] each begin a test region.
            for region in parts.dropFirst() {
                if region.contains(".disabled") { continue }   // disabled trait → not an enabled test
                enabledRegions.append(region)
                // (3) test-side Given holes: a genesisTODO( call (or GenesisTODO.notImplemented) left in an
                // enabled @Test. String content is already blanked, so a message merely mentioning the token
                // does not count; a real `try genesisTODO("...")` call (token outside the string) does.
                for raw in region.components(separatedBy: "\n") {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard line.contains("genesisTODO(") || line.contains("GenesisTODO.notImplemented") else { continue }
                    testHoles.append(Hole(file: rel, snippet: line))
                }
            }
        }

        var uncovered: [String] = []
        for code in invariantCodes.sorted() {
            let covered = enabledRegions.contains { referencesCode($0, code) }
            if !covered { uncovered.append(code) }
        }

        return Result(remainingMarkers: markers, uncoveredInvariants: uncovered, remainingTestHoles: testHoles)
    }

    // MARK: - helpers

    /// Whole-token match for `.<code>` in an ALREADY-sanitized region — a substring `contains` would let
    /// `.permission` be falsely "covered" by a test referencing `.permissionDenied` (prefix collision).
    /// Require `.<code>` NOT followed by an identifier character. The caller passes sanitizeSwift output, so a
    /// `.<code>` token inside a thunk message / string has already been blanked (only a live assertion counts).
    static func referencesCode(_ sanitizedRegion: String, _ code: String) -> Bool {
        let pattern = "\\.\(NSRegularExpression.escapedPattern(for: code))(?![A-Za-z0-9_])"
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return sanitizedRegion.contains(".\(code)")
        }
        return re.firstMatch(in: sanitizedRegion, range: NSRange(sanitizedRegion.startIndex..., in: sanitizedRegion)) != nil
    }

    static func swiftFiles(in root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "swift" { out.append(url) }
        return out
    }

    /// Enum case identifiers declared on `case <ident>` lines (single-case form; the renderer emits one per line).
    /// Caller passes sanitizeSwift output, so a `case` mentioned in a comment/string is not seen.
    static func enumCases(in sanitized: String) -> [String] {
        var out: [String] = []
        for raw in sanitized.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("case ") else { continue }
            let rest = line.dropFirst("case ".count)
            // take the leading identifier (stop at space, (, :, ,)
            let ident = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !ident.isEmpty { out.append(String(ident)) }
        }
        return out
    }

    /// Single-pass lexer that blanks the CONTENT of Swift comments and string literals (newlines preserved 1:1,
    /// so `@Test` segmentation and line-based scans survive). Handles line comments (`//`), NESTED block comments
    /// (`/* /* */ */`), normal strings (`"..."` with `\"` escapes), multiline strings (`"""..."""`), and raw
    /// strings (`#"..."#` / `##"..."##`, incl. raw multiline). A real code token (a `genesisTODO(` call, a
    /// `.<errorCode>` in a live assertion, a `.disabled` trait) survives; the same token inside a comment or a
    /// string literal is removed. Because it tracks state in ONE pass it cannot desync (the two-pass naive strip
    /// it replaces could, producing a DANGEROUS false-green that hid real holes — Phase 1.z impl-verify F1/F2/F3).
    static func sanitizeSwift(_ s: String) -> String {
        let chars = Array(s)
        let n = chars.count
        var out: [Character] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            let c = chars[i]
            // line comment //
            if c == "/", i + 1 < n, chars[i + 1] == "/" {
                i += 2
                while i < n, chars[i] != "\n" { i += 1 }   // leave the \n for the outer loop
                continue
            }
            // block comment /* ... */ (nested)
            if c == "/", i + 1 < n, chars[i + 1] == "*" {
                i += 2
                var depth = 1
                while i < n, depth > 0 {
                    if chars[i] == "/", i + 1 < n, chars[i + 1] == "*" { depth += 1; i += 2; continue }
                    if chars[i] == "*", i + 1 < n, chars[i + 1] == "/" { depth -= 1; i += 2; continue }
                    if chars[i] == "\n" { out.append("\n") }
                    i += 1
                }
                continue
            }
            // raw string: one-or-more '#' then '"' (possibly """). closer = '"'(or '"""') followed by the same # count.
            if c == "#" {
                var h = 0
                var j = i
                while j < n, chars[j] == "#" { h += 1; j += 1 }
                if j < n, chars[j] == "\"" {
                    let triple = (j + 2 < n && chars[j + 1] == "\"" && chars[j + 2] == "\"")
                    i = j + (triple ? 3 : 1)
                    while i < n {
                        var matched = false
                        if chars[i] == "\"" {
                            if triple {
                                if i + 2 < n, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                                    var k = i + 3, hh = 0
                                    while k < n, hh < h, chars[k] == "#" { hh += 1; k += 1 }
                                    if hh == h { i = k; matched = true }
                                }
                            } else {
                                var k = i + 1, hh = 0
                                while k < n, hh < h, chars[k] == "#" { hh += 1; k += 1 }
                                if hh == h { i = k; matched = true }
                            }
                        }
                        if matched { break }
                        if chars[i] == "\n" { out.append("\n") }
                        i += 1
                    }
                    continue
                }
                out.append(c); i += 1; continue   // a lone '#' (e.g. #if / #available)
            }
            // multiline string """
            if c == "\"", i + 2 < n, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                i += 3
                while i < n {
                    if chars[i] == "\"", i + 2 < n, chars[i + 1] == "\"", chars[i + 2] == "\"" { i += 3; break }
                    if chars[i] == "\n" { out.append("\n") }
                    i += 1
                }
                continue
            }
            // normal string "
            if c == "\"" {
                i += 1
                while i < n {
                    if chars[i] == "\\" { i += 2; continue }     // skip escaped char (e.g. \")
                    if chars[i] == "\"" { i += 1; break }
                    if chars[i] == "\n" { break }                // unterminated single-line string (malformed) — stop, leave \n for outer loop
                    i += 1
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}
