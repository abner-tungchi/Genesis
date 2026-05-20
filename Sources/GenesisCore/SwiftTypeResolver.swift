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

        if knownCustomTypes.contains(trimmed) {
            return trimmed
        }

        throw GenesisError.bundleInvalid(
            reason: "unknown type '\(rawType)' — not a primitive, container, or known DTO. "
                + "Either add to bundle.dtos[] or wait for swift-adapter.yaml support (Phase 1.c)."
        )
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
