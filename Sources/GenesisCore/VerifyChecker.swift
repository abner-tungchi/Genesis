import Foundation

/// Phase 1.y/1.z: the structural honesty gate that replaces #error's compile-time enforcement.
/// `genesis verify` (run in a generated project root) checks four things WITHOUT needing the bundle:
///  1. no GenesisTODO.notImplemented marker remains in Sources/ (unfilled domain holes).
///  2. every aggregate invariant errorCode (read from <A>Error.swift's enum cases — the bundle is not
///     copied into the generated tree) has ≥1 ENABLED (non-.disabled) test referencing it via a LIVE
///     assertion. Non-circular backstop for the no-op ensureInvariant: it checks the STRUCTURAL fact that
///     an enabled invariant test exists, NOT that test-gen synthesized the invariant-tripping state.
///  3. (Phase 1.z FIX-2) no remaining test-side Given hole: an enabled @Test in Tests/ that still calls the
///     `genesisTODO(...)` arrange-thunk (or GenesisTODO.notImplemented) is an unfilled Given — the enabled-red
///     world moved the hole from Sources(#error/.disabled) into Tests/, so the gate follows it.
///  4. (read side) no remaining read-side hole: (a) a Presenter `when(readModel: inout …, event: <E>)` whose body is
///     still an unfilled / half-filled stub by EXACTLY the /readmodel-mutation Phase 2 rule (placeholder
///     `_ = readModel` / `_ = event` present, or no mutation and no `// readmodel-mutation: no-op` marker) —
///     such a stub compiles and runs but leaves the read model permanently empty; (b) a read-side
///     ApplicationService whose `fatalError("TODO(/presenter-fill skill)…")` is still a live call — a read API
///     call would crash. These holes are deliberately NOT GenesisTODO throws (DDDKit projectors swallow thrown
///     errors into nil, and the stub shape is the contract /readmodel-mutation and /presenter-fill key on).
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
        public let remainingReadSideHoles: [Hole]  // unfilled Presenter when() stubs + read-side AS fatalError TODOs
        public var passed: Bool {
            remainingMarkers.isEmpty && uncoveredInvariants.isEmpty && remainingTestHoles.isEmpty
                && remainingReadSideHoles.isEmpty
        }
    }

    public static func verify(projectRoot: URL) -> Result {
        let sourcesURL = projectRoot.appendingPathComponent("Sources")
        let testsURL = projectRoot.appendingPathComponent("Tests")

        var markers: [Hole] = []
        var invariantCodes: Set<String> = []
        var readSideHoles: [Hole] = []

        for url in swiftFiles(in: sourcesURL) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rel = relativePath(url, in: projectRoot)

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

            // (4) read-side holes (Presenter when() stubs, read-side AS fatalError TODO).
            readSideHoles.append(contentsOf: scanReadSide(rel: rel, rawLines: rawLines, sanLines: sanLines))

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
            let rel = relativePath(url, in: projectRoot)
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

        return Result(remainingMarkers: markers, uncoveredInvariants: uncovered, remainingTestHoles: testHoles,
                      remainingReadSideHoles: readSideHoles)
    }

    // MARK: - report formatting

    /// Indented report lines for a hole list: the first `limit` holes, then `    … and N more` when truncated
    /// (the caller prints the total in the heading line, so nothing is silently dropped).
    public static func formatHoleList(_ holes: [Hole], limit: Int = 40) -> [String] {
        var out = holes.prefix(limit).map { "    \($0.file): \($0.snippet)" }
        if holes.count > limit { out.append("    … and \(holes.count - limit) more") }
        return out
    }

    // MARK: - read-side holes

    /// Marker the /readmodel-mutation skill writes when the human answers "does not affect this read model".
    static let readModelNoOpMarker = #/^//\s*readmodel-mutation:\s*no-op/#
    /// A read-side AS stub left by Phase 1.k: `fatalError("TODO(/presenter-fill skill)…")`.
    static let presenterFillMarker = "TODO(/presenter-fill"

    /// Read-side holes in ONE source file. `rawLines` / `sanLines` are the file's raw and `sanitizeSwift`
    /// lines (1:1). Judgement is made on the sanitized lines (comments / string content gone); only the
    /// comment-shaped no-op marker and the AS message text are read from the raw lines. Fail-closed: when the
    /// 1:1 line mapping is broken, raw lines are used for the AS scan (over-flag) and Presenter bodies are skipped
    /// only if no `when(readModel:` signature is found at all.
    static func scanReadSide(rel: String, rawLines: [String], sanLines: [String]) -> [Hole] {
        var holes: [Hole] = []
        let aligned = rawLines.count == sanLines.count
        let san = aligned ? sanLines : rawLines

        // (b) read-side AS: a LIVE `fatalError(` whose raw line carries the /presenter-fill TODO text.
        for (idx, s) in san.enumerated() where s.contains("fatalError(") {
            let raw = rawLines[idx]
            if raw.contains(presenterFillMarker) {
                holes.append(Hole(file: rel, snippet: raw.trimmingCharacters(in: .whitespaces)))
            }
        }

        // (a) Presenter when(readModel: inout …, event: <E>) bodies — same rule as /readmodel-mutation Phase 2.
        let text = san.joined(separator: "\n")
        let sigPattern = #"func\s+when\s*\(\s*readModel\s*:\s*inout\s+[A-Za-z0-9_.<>?]+\s*,\s*event\s*:\s*([A-Za-z0-9_.]+)\s*\)"#
        guard let sig = try? NSRegularExpression(pattern: sigPattern) else { return holes }
        let ns = text as NSString
        for m in sig.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let event = ns.substring(with: m.range(at: 1))
            // body = balanced { ... } after the signature (past `throws` etc.)
            var i = m.range.location + m.range.length
            let sigEnd = i
            while i < ns.length, ns.character(at: i) != 0x7B /* { */, i - sigEnd <= 60 { i += 1 }   // `throws`, newlines
            guard i < ns.length, ns.character(at: i) == 0x7B else { continue }
            let bodyStart = i + 1
            var depth = 1
            i = bodyStart
            while i < ns.length, depth > 0 {
                let c = ns.character(at: i)
                if c == 0x7B { depth += 1 } else if c == 0x7D { depth -= 1 }
                i += 1
            }
            let bodyEnd = depth == 0 ? i - 1 : ns.length
            let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            let firstLine = ns.substring(to: bodyStart).components(separatedBy: "\n").count - 1   // 0-based line of `{`
            let bodyLineCount = body.components(separatedBy: "\n").count
            let bodySan = body.components(separatedBy: "\n")
            let bodyRaw = aligned
                ? Array(rawLines[firstLine ..< min(rawLines.count, firstLine + bodyLineCount)])
                : bodySan

            let state = whenBodyState(sanLines: bodySan, rawLines: bodyRaw)
            if let reason = state {
                holes.append(Hole(file: rel, snippet: "when(readModel:event: \(event)) — \(reason)"))
            }
        }
        return holes
    }

    /// nil = filled / explicit no-op; otherwise the reason it is a hole. Mirrors /readmodel-mutation Phase 2:
    /// 未填＝placeholder present; 半填＝(placeholder mixed with mutation) or (no mutation and no no-op marker);
    /// 已填＝no placeholder AND (mutation OR no-op marker). Placeholders are judged on sanitized text.
    static func whenBodyState(sanLines: [String], rawLines: [String]) -> String? {
        var hasRM = false, hasEv = false, hasMutation = false, hasStatement = false
        for s in sanLines {
            let line = s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            if line.isEmpty { continue }
            if line.range(of: #"^_\s*=\s*readModel$"#, options: .regularExpression) != nil { hasRM = true; continue }
            if line.range(of: #"^_\s*=\s*event$"#, options: .regularExpression) != nil { hasEv = true; continue }
            hasStatement = true
            if line.contains("readModel.") || line.contains(".append(") || line.contains(".removeAll(")
                || line.range(of: #"\]\s*\.[A-Za-z_]"#, options: .regularExpression) != nil
                || line.range(of: #"\breadModel\s*="#, options: .regularExpression) != nil {
                hasMutation = true
            }
        }
        // no-op marker is a COMMENT: the raw line is comment-only, and the sanitized line is empty
        // (so a string literal that merely spells the marker cannot silence a hole).
        var hasNoOp = false
        for (idx, raw) in rawLines.enumerated() where idx < sanLines.count {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if sanLines[idx].trimmingCharacters(in: .whitespaces).isEmpty, t.firstMatch(of: readModelNoOpMarker) != nil {
                hasNoOp = true
            }
        }
        if hasRM && hasEv && !hasMutation && !hasStatement { return "unfilled (still `_ = readModel` / `_ = event`)" }
        if hasRM || hasEv { return "half-filled (leftover `_ = readModel` / `_ = event` placeholder)" }
        if hasMutation || hasNoOp { return nil }
        return "half-filled (no mutation and no `// readmodel-mutation: no-op` marker)"
    }

    // MARK: - helpers

    /// Path of `url` relative to `root`, symlink-safe (macOS /var vs /private/var would otherwise leave the
    /// root prefix in place and print a mangled path).
    static func relativePath(_ url: URL, in root: URL) -> String {
        let r = root.resolvingSymlinksInPath().path + "/"
        let p = url.resolvingSymlinksInPath().path
        return p.hasPrefix(r) ? String(p.dropFirst(r.count)) : url.path.replacingOccurrences(of: root.path + "/", with: "")
    }

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
