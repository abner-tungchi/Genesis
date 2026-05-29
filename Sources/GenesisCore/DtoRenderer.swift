import Foundation

public enum DtoRenderer {
    public static func render(
        dto: DtoSpec,
        hostTarget: String,
        knownCustomTypes: Set<String>,
        adapter: Adapter = .defaultFor(contextName: "")
    ) throws -> (path: String, content: String, role: String) {
        // Phase 1.l.1.1: prefer explicit dtoKind (Cosmogony v19+) over description heuristic (legacy).
        let isEnum: Bool
        if let dk = dto.dtoKind, !dk.isEmpty {
            isEnum = (dk == "enum")
        } else {
            isEnum = isEnumKind(description: dto.description)
        }
        let kind = isEnum ? "enum" : "struct"
        // Phase 1.e: emit Codable conformance so plugin-generated event structs (which extend Codable
        // and reference DTOs as field types) can synthesize their Codable members. OC convention:
        //   enum: `: String, Codable` (String raw type for stable wire format)
        //   struct: `: Codable, Sendable`
        let conformances = isEnum ? ": String, Codable" : ": Codable, Sendable"

        var body: [String] = []
        if isEnum {
            // Phase 1.l.1.1: Cosmogony v19+ stores enum values in `cases`; legacy bundle puts them in `fields`.
            let enumCases = !dto.cases.isEmpty ? dto.cases : dto.fields.map(\.name)
            for c in enumCases {
                body.append("    case \(c)")
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
        // Phase 1.p: when DTO has explicit scope (Cosmogony v19+) and a separate domainTypeName,
        // append bi-directional `init(from:)` mapper extensions at the same file (OC convention).
        // D3: per-UC / per-readmodel / per-aggregate DTO files contain DEF + mappers in one file.
        // The domain type itself is emitted separately by SharedTargetRenderer (domain mirror at
        // <A>Aggregate/<Domain>.swift) — these mappers reference that type by name.
        var output = rendered.output
        if let mapperBlock = renderBidirectionalMappers(dto: dto, isEnum: isEnum) {
            // Ensure trailing newline before appending extensions for clean Swift formatting.
            if !output.hasSuffix("\n") { output += "\n" }
            output += "\n" + mapperBlock
        }
        let path = "Sources/\(hostTarget)/\(dto.name).swift"
        return (path, output, "dto")
    }

    /// Phase 1.p D3 + D19: emit bi-directional `init(from:)` mappers when DTO declares
    /// explicit scope (Cosmogony v19+) and `domainTypeName ≠ name`. OC pattern verbatim
    /// (BusinessTaxFilingMethodDto.swift): both `extension <Domain> { init(from dto:) }`
    /// and `extension <Dto> { init(from domain:) }` regardless of usage direction (cheap
    /// and matches OC; usage-direction nuance handled at AS execute body, not at DTO file).
    /// Returns nil when not applicable — legacy contextShared / no domain split DTOs
    /// keep their existing emit shape.
    private static func renderBidirectionalMappers(dto: DtoSpec, isEnum: Bool) -> String? {
        // Only emit mappers for scope-explicit DTOs (Phase 1.p territory).
        guard let scope = dto.scope, scope != "contextShared" else { return nil }
        // Domain type name must be distinct from DTO name (otherwise identity-mapper
        // collision — Phase 1.o.1 F6: skip emit when names equal).
        guard let domainName = dto.domainTypeName,
              !domainName.isEmpty,
              domainName != dto.name else { return nil }

        if isEnum {
            let cases = !dto.cases.isEmpty ? dto.cases : dto.fields.map(\.name)
            let dtoToDomainCases = cases.map { "        case .\($0): self = .\($0)" }.joined(separator: "\n")
            let domainToDtoCases = cases.map { "        case .\($0): self = .\($0)" }.joined(separator: "\n")
            return """
            extension \(domainName) {
                package init(from dto: \(dto.name)) {
                    switch dto {
            \(dtoToDomainCases)
                    }
                }
            }

            extension \(dto.name) {
                package init(from domain: \(domainName)) {
                    switch domain {
            \(domainToDtoCases)
                    }
                }
            }

            """
        } else {
            // struct: field-by-field assignment (assumes domain and DTO share field names — OC convention)
            let dtoToDomainFields = dto.fields.map { "        self.\($0.name) = dto.\($0.name)" }.joined(separator: "\n")
            let domainToDtoFields = dto.fields.map { "        self.\($0.name) = domain.\($0.name)" }.joined(separator: "\n")
            return """
            extension \(domainName) {
                package init(from dto: \(dto.name)) {
            \(dtoToDomainFields)
                }
            }

            extension \(dto.name) {
                package init(from domain: \(domainName)) {
            \(domainToDtoFields)
                }
            }

            """
        }
    }

    static func isEnumKind(description: String) -> Bool {
        description.range(of: "enum", options: .caseInsensitive) != nil
    }
}
