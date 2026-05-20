import Foundation

public enum DtoRenderer {
    public static func render(
        dto: DtoSpec,
        hostTarget: String,
        knownCustomTypes: Set<String>,
        adapter: Adapter = .defaultFor(contextName: "")
    ) throws -> (path: String, content: String, role: String) {
        let isEnum = isEnumKind(description: dto.description)
        let kind = isEnum ? "enum" : "struct"
        // Phase 1.e: emit Codable conformance so plugin-generated event structs (which extend Codable
        // and reference DTOs as field types) can synthesize their Codable members. OC convention:
        //   enum: `: String, Codable` (String raw type for stable wire format)
        //   struct: `: Codable, Sendable`
        let conformances = isEnum ? ": String, Codable" : ": Codable, Sendable"

        var body: [String] = []
        if isEnum {
            for field in dto.fields {
                body.append("    case \(field.name)")
            }
        } else {
            for field in dto.fields {
                let resolved = try SwiftTypeResolver.resolve(
                    rawType: field.rawType,
                    knownCustomTypes: knownCustomTypes,
                    adapter: adapter
                )
                body.append("    package let \(field.name): \(resolved)")
            }
        }

        let template = try TemplateLoader.loadTemplate(name: "Dto.swift", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "Kind": kind,
                "DtoName": dto.name,
                "Conformances": conformances,
                "DtoBody": body.joined(separator: "\n"),
            ]
        )
        let path = "Sources/\(hostTarget)/\(dto.name).swift"
        return (path, rendered.output, "dto")
    }

    static func isEnumKind(description: String) -> Bool {
        description.range(of: "enum", options: .caseInsensitive) != nil
    }
}
