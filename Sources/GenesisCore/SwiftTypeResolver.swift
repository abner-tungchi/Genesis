import Foundation

public enum SwiftTypeResolver {
    private static let primitives: Set<String> = [
        "String", "Int", "Bool", "Decimal", "Date", "UUID", "Float", "Double",
    ]

    /// Adapter-aware resolution. Applies typeMapping first, then falls through.
    public static func resolve(
        rawType: String,
        knownCustomTypes: Set<String>,
        adapter: Adapter
    ) throws -> String {
        let trimmed = rawType.trimmingCharacters(in: .whitespaces)
        if let mapped = adapter.typeMapping[trimmed] {
            return mapped
        }
        return try resolve(rawType: rawType, knownCustomTypes: knownCustomTypes)
    }

    public static func resolve(rawType: String, knownCustomTypes: Set<String>) throws -> String {
        let trimmed = rawType.trimmingCharacters(in: .whitespaces)

        if primitives.contains(trimmed) {
            return trimmed
        }

        if let inner = matchContainer(trimmed, prefix: "Array[", suffix: "]") {
            let resolvedInner = try resolve(rawType: inner, knownCustomTypes: knownCustomTypes)
            return "[\(resolvedInner)]"
        }

        if let inner = matchContainer(trimmed, prefix: "Set<", suffix: ">") {
            _ = try resolve(rawType: inner, knownCustomTypes: knownCustomTypes)
            return trimmed
        }

        // Phase 1.l.1: Cosmogony bracket notation — `Set[X]` → `Set<X>`
        if let inner = matchContainer(trimmed, prefix: "Set[", suffix: "]") {
            let resolvedInner = try resolve(rawType: inner, knownCustomTypes: knownCustomTypes)
            return "Set<\(resolvedInner)>"
        }

        if knownCustomTypes.contains(trimmed) {
            return trimmed
        }

        throw GenesisError.bundleInvalid(
            reason: "unknown type '\(rawType)' — not a primitive, container, or known DTO. "
                + "Either add to bundle.dtos[] or wait for swift-adapter.yaml support (Phase 1.c)."
        )
    }

    /// Non-throwing notation translation for types that reach a renderer unresolved
    /// (read model stored fields / key, presenter input). Rewrites Cosmogony bracket notation
    /// (`Array[X]` -> `[X]`, `Set[X]` -> `Set<X>`, recursively) and keeps trailing `?` markers.
    /// Unlike `resolve`, unknown names pass through unchanged (they may be types from other
    /// modules); the swift build is the arbiter for those. Adapter typeMapping wins first.
    public static func translateNotation(rawType: String, adapter: Adapter? = nil) -> String {
        let trimmed = rawType.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("?") {
            return translateNotation(rawType: String(trimmed.dropLast()), adapter: adapter) + "?"
        }
        if let mapped = adapter?.typeMapping[trimmed] { return mapped }
        if let inner = matchContainer(trimmed, prefix: "Array[", suffix: "]") {
            return "[\(translateNotation(rawType: inner, adapter: adapter))]"
        }
        if let inner = matchContainer(trimmed, prefix: "Set[", suffix: "]") {
            return "Set<\(translateNotation(rawType: inner, adapter: adapter))>"
        }
        return trimmed
    }

    private static func matchContainer(_ s: String, prefix: String, suffix: String) -> String? {
        guard s.hasPrefix(prefix), s.hasSuffix(suffix), s.count > prefix.count + suffix.count else {
            return nil
        }
        let start = s.index(s.startIndex, offsetBy: prefix.count)
        let end = s.index(s.endIndex, offsetBy: -suffix.count)
        return String(s[start..<end])
    }
}
