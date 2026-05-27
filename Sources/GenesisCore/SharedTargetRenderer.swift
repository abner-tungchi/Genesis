import Foundation

public enum SharedTargetRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        ownership: [String: TypeOwnership]
    ) throws -> [(path: String, content: String, role: String)] {
        var outputs: [(String, String, String)] = []
        outputs.append(contentsOf: try renderBundleDtosAndCustomTypes(
            bundle: bundle, contextName: contextName, adapter: adapter, ownership: ownership
        ))
        outputs.append(contentsOf: try renderInfraFiles(contextName: contextName))
        return outputs
    }

    /// Phase 1.b/1.c legacy: bundle-driven DTOs + adapter customTypes.
    private static func renderBundleDtosAndCustomTypes(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        ownership: [String: TypeOwnership]
    ) throws -> [(String, String, String)] {
        let sharedTarget = "\(contextName)Shared"

        // Build merged custom type list (adapter wins on name collision).
        // Phase 1.e: typedStruct auto-wrapper generation removed — kit enforces ID == String,
        // so id wrappers are no longer structurally valid. User-side {A}ID wrappers (if needed)
        // are now an explicit customTypes entry in swift-adapter.yaml, not auto-generated.
        var byName: [String: CustomTypeSpec] = [:]
        for ct in adapter.customTypes {
            byName[ct.name] = ct
        }

        let knownCustomTypes = Set(bundle.dtos.map { $0.name }).union(byName.keys)

        var outputs: [(String, String, String)] = []
        var emittedNames: Set<String> = []

        // Emit adapter / auto-generated custom types
        for name in byName.keys.sorted() {
            let ct = byName[name]!
            let dir: String
            switch ownership[name] {
            case .contextShared, nil:
                dir = sharedTarget
            case .ownedBy(let aggName):
                dir = "\(aggName)Aggregate"
            }
            outputs.append(try renderCustomType(ct, dir: dir, knownCustomTypes: knownCustomTypes, adapter: adapter))
            emittedNames.insert(name)
        }

        // Emit bundle.dtos[] (skip ones overridden by adapter)
        for dto in bundle.dtos where !emittedNames.contains(dto.name) {
            guard let own = ownership[dto.name] else { continue }
            let hostTarget: String
            switch own {
            case .contextShared:
                hostTarget = sharedTarget
            case .ownedBy(let aggName):
                hostTarget = "\(aggName)Aggregate"
            }
            let rendered = try DtoRenderer.render(
                dto: dto,
                hostTarget: hostTarget,
                knownCustomTypes: knownCustomTypes,
                adapter: adapter
            )
            outputs.append(rendered)
            emittedNames.insert(dto.name)
        }

        return outputs
    }

    /// Phase 1.f: emit ContextShared infrastructure (ApplicationService protocol, ContextError wrapper,
    /// Iso8601 helpers, etc.). Universal — emitted regardless of bundle DTO / customType content
    /// so per-feature skills (`/api`, `/usecase`, `/readmodel`) can rely on the layer existing.
    private static func renderInfraFiles(contextName: String) throws -> [(String, String, String)] {
        let sharedDir = "Sources/\(contextName)Shared"
        var outputs: [(String, String, String)] = []

        // 8 Swift infra files: load template, write as-is (no placeholder substitution needed)
        let infraFiles = [
            "ApplicationService.swift",
            "ContextError.swift",
            "Iso8601.swift",
            "InvalidDecimalStringError.swift",
            "ProjectionReadInconsistency.swift",
            "String+IsBlank.swift",
            "String+PascalCase.swift",
            "String+StrippingPrefix.swift",
        ]
        for fileName in infraFiles {
            let template = try TemplateLoader.loadTemplate(name: "Shared/\(fileName)", ext: "template")
            outputs.append(("\(sharedDir)/\(fileName)", template, "sharedInfra"))
        }

        // README.md with placeholder substitution. vars dict MUST include all 3 keys
        // ContextName/GenesisVersion/Date — README template uses all 3; precondition asserts no leftover.
        let readmeTemplate = try TemplateLoader.loadTemplate(name: "Shared/README.md", ext: "template")
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let readmeRendered = TemplateRenderer.render(
            template: readmeTemplate,
            vars: [
                "ContextName": contextName,
                "GenesisVersion": GenesisCoreVersion.current,
                "Date": today,
            ]
        )
        precondition(
            readmeRendered.unresolvedVariables.isEmpty,
            "README.md.template has unresolved placeholder(s): \(readmeRendered.unresolvedVariables)"
        )
        outputs.append(("\(sharedDir)/README.md", readmeRendered.output, "sharedInfra"))

        return outputs
    }

    private static func renderCustomType(
        _ ct: CustomTypeSpec,
        dir: String,
        knownCustomTypes: Set<String>,
        adapter: Adapter
    ) throws -> (String, String, String) {
        switch ct.kind {
        case .enum:
            return try renderEnum(ct, dir: dir)
        case .valueObject:
            return try renderValueObject(ct, dir: dir, knownCustomTypes: knownCustomTypes, adapter: adapter)
        case .identifier:
            return try renderIdWrapper(ct, dir: dir, knownCustomTypes: knownCustomTypes, adapter: adapter)
        }
    }

    private static func renderEnum(_ ct: CustomTypeSpec, dir: String) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "Dto.swift", ext: "template")
        let body = (ct.cases ?? []).map { "    case \($0)" }.joined(separator: "\n")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "Kind": "enum",
                "DtoName": ct.name,
                "Conformances": ": String, Codable",  // Phase 1.e: plugin-generated events Codable-conform
                "DtoBody": body,
            ]
        )
        return ("Sources/\(dir)/\(ct.name).swift", rendered.output, "customEnum")
    }

    private static func renderValueObject(
        _ ct: CustomTypeSpec,
        dir: String,
        knownCustomTypes: Set<String>,
        adapter: Adapter
    ) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "ValueObject.swift", ext: "template")
        let underlying = try SwiftTypeResolver.resolve(
            rawType: ct.underlying ?? "String",
            knownCustomTypes: knownCustomTypes,
            adapter: adapter
        )
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "Name": ct.name,
                "Underlying": underlying,
            ]
        )
        return ("Sources/\(dir)/\(ct.name).swift", rendered.output, "valueObject")
    }

    private static func renderIdWrapper(
        _ ct: CustomTypeSpec,
        dir: String,
        knownCustomTypes: Set<String>,
        adapter: Adapter
    ) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "IdWrapper.swift", ext: "template")
        let underlying = try SwiftTypeResolver.resolve(
            rawType: ct.underlying ?? "UUID",
            knownCustomTypes: knownCustomTypes,
            adapter: adapter
        )
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "Name": ct.name,
                "Underlying": underlying,
            ]
        )
        return ("Sources/\(dir)/\(ct.name).swift", rendered.output, "idWrapper")
    }
}
