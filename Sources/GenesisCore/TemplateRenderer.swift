import Foundation

public struct RenderResult: Sendable, Equatable {
    public let output: String
    public let unresolvedVariables: [String]

    public init(output: String, unresolvedVariables: [String]) {
        self.output = output
        self.unresolvedVariables = unresolvedVariables
    }
}

public enum TemplateRenderer {
    private static let variablePattern: NSRegularExpression = {
        // Force-unwrap: the pattern is a compile-time constant known to be valid.
        try! NSRegularExpression(pattern: "\\{([A-Za-z][A-Za-z0-9_]*)\\}")
    }()

    public static func render(template: String, vars: [String: String]) -> RenderResult {
        let range = NSRange(template.startIndex..., in: template)
        let allVarNames: Set<String> = Set(
            variablePattern.matches(in: template, range: range)
                .compactMap { Range($0.range(at: 1), in: template).map { String(template[$0]) } }
        )

        var output = template
        var unresolved: [String] = []
        for varName in allVarNames.sorted() {
            if let value = vars[varName] {
                output = output.replacingOccurrences(of: "{\(varName)}", with: value)
            } else {
                unresolved.append(varName)
            }
        }
        return RenderResult(output: output, unresolvedVariables: unresolved)
    }
}
