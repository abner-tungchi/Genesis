import Foundation

public enum CaseTransformer {
    public static func upperCamel(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    public static func lowerCamel(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    /// Convert PascalCase / camelCase to UPPER_SNAKE_CASE.
    ///
    /// Boundaries:
    /// - lowercase → uppercase (e.g. "myApp" → "MY_APP")
    /// - All-caps runs preserved (e.g. "XMLAPI" → "XMLAPI", "XMLAPIContext" stripping
    ///   "Context" → "XMLAPI" → "XMLAPI")
    /// - Lower→Upper junction (e.g. "iAmContext" → "I_AM_CONTEXT")
    ///
    /// Used by Phase 1.g `streamPrefix` derivation when alias-map miss.
    public static func upperSnake(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var result = ""
        let chars = Array(s)
        for i in 0..<chars.count {
            let c = chars[i]
            if i > 0 {
                let prev = chars[i - 1]
                // Lower→Upper: insert underscore
                if prev.isLowercase && c.isUppercase {
                    result.append("_")
                }
                // AllCaps→Lower (camel-case end of acronym, e.g. "XMLAPIClient" → "XMLAPI_CLIENT"):
                // detect uppercase followed by lowercase where the prior char is also uppercase
                else if i + 1 < chars.count
                    && prev.isUppercase && c.isUppercase && chars[i + 1].isLowercase {
                    result.append("_")
                }
            }
            result.append(Character(c.uppercased()))
        }
        return result
    }
}
