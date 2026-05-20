import Foundation

/// Phase 1.h: ApplicationService scaffold + DTO mapper codegen renderer (Variant A v1).
///
/// Pure function of bundle (per audit H2 — no FileManager reads during render).
///
/// Emits:
///   1. Per write UC: `Sources/<A>Aggregate/Adapter/<UC>/<UC>ApplicationService.swift`
///      (scaffold with TODO body for /api skill to fill)
///   2. Per bundle.dtos[] non-context-shared entry: `Sources/<A>Aggregate/Adapter/Dto/<X>Dto+Domain.swift`
///      (enum: full bi-directional mapper; struct: scaffold with TODO body)
///
/// **Defer to Phase 1.i**:
///   - ApiHandler.swift (needs OpenAPIGenerator plugin + openapi.yaml)
///   - ApiComponents+Error.swift
///   - openapi.yaml stub emission
///   - PackageRenderer OpenAPIGenerator plugin extension
public enum ApiRenderer {

    public static let readUcPrefixes: [String] = ["get", "list", "find"]

    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)] {
        var outputs: [(String, String, String)] = []
        let sharedImport = "import \(contextName)Shared"

        // --- Per-UC ApplicationService scaffolds ---
        let writeUseCases = bundle.useCases.filter { !isReadUseCase($0.useCase) }
        for uc in writeUseCases {
            guard let aggregate = bundle.aggregates.first(where: { $0.aggregateSpecId == uc.aggregateSpecId }) else {
                continue  // already enforced by BundleParser, defensive
            }
            let ucPascal = CaseTransformer.upperCamel(uc.useCase)
            let asPath = "Sources/\(aggregate.name)Aggregate/Adapter/\(ucPascal)/\(ucPascal)ApplicationService.swift"
            if existingPaths.contains(asPath) { continue }  // scaffold-once

            let content = try renderApplicationService(
                useCase: uc,
                ucPascal: ucPascal,
                aggregate: aggregate,
                sharedImport: sharedImport
            )
            outputs.append((asPath, content, "applicationService"))
        }

        // --- Per-DTO mapper files (per-aggregate only; context-shared handled by SharedTargetRenderer) ---
        // v1: assume DTO applies to FIRST aggregate (multi-aggregate assignment defer v2).
        guard let firstAggregate = bundle.aggregates.first else { return outputs }

        for dto in bundle.dtos where !dto.isContextShared {
            let dtoKind = resolveDtoKind(dto)
            if dtoKind == "union" {
                // Defer Phase 1.i.2 — skip with no emit
                continue
            }
            let mapperPath = "Sources/\(firstAggregate.name)Aggregate/Adapter/Dto/\(dto.name)+Domain.swift"
            if existingPaths.contains(mapperPath) { continue }

            let content: String
            switch dtoKind {
            case "enum":
                content = try renderEnumMapper(dto: dto, sharedImport: sharedImport)
                outputs.append((mapperPath, content, "dtoEnumMapper"))
            case "struct":
                content = try renderStructMapper(dto: dto, sharedImport: sharedImport)
                outputs.append((mapperPath, content, "dtoStructMapper"))
            default:
                continue
            }
        }
        return outputs
    }

    // MARK: - Helpers

    static func isReadUseCase(_ name: String) -> Bool {
        let lc = name.lowercased()
        return readUcPrefixes.contains { lc.hasPrefix($0) }
    }

    static func resolveDtoKind(_ dto: DtoSpec) -> String {
        if let explicit = dto.dtoKind, !explicit.isEmpty {
            return explicit
        }
        // Legacy fallback (audit M3 backwards-compat): description-based inference
        if dto.description.range(of: "enum", options: .caseInsensitive) != nil {
            return "enum"
        }
        return "struct"
    }

    static func domainTypeName(for dto: DtoSpec) -> String {
        if let explicit = dto.domainTypeName, !explicit.isEmpty {
            return explicit
        }
        // Default: strip "Dto" suffix from name (e.g. "AccountingTypeDto" → "AccountingType")
        if dto.name.hasSuffix("Dto") {
            return String(dto.name.dropLast("Dto".count))
        }
        return dto.name
    }

    // MARK: - Application Service renderer

    private static func renderApplicationService(
        useCase: UseCaseSpec,
        ucPascal: String,
        aggregate: AggregateSpec,
        sharedImport: String
    ) throws -> String {
        let template = try TemplateLoader.loadTemplate(name: "Api/ApplicationService.swift", ext: "template")
        let aggIdName = aggregate.identityName

        // Filter Service Input: exclude operatorId (HTTP transport metadata) and aggregate ID (positional)
        let middleFields = useCase.input.filter { $0.name != "operatorId" && $0.name != aggIdName }

        // Resolve raw bundle types (e.g. "Array[String]" → "[String]") via SwiftTypeResolver per existing convention
        let knownTypes = Set<String>()  // ApiRenderer doesn't track custom types; bundle.dtos[] resolved separately
        let resolvedFields = try middleFields.map { f -> (String, String) in
            let resolved = try SwiftTypeResolver.resolve(rawType: f.rawType, knownCustomTypes: knownTypes)
            return (f.name, resolved)
        }

        let inputFields: String = resolvedFields
            .map { "    package let \($0.0): \($0.1)" }
            .joined(separator: "\n")
        let initParamsMid: String = resolvedFields
            .map { ",\n        \($0.0): \($0.1)" }
            .joined(separator: "")
        let initAssignments: String = resolvedFields
            .map { "        self.\($0.0) = \($0.0)" }
            .joined(separator: "\n")

        return TemplateRenderer.render(template: template, vars: [
            "SharedImport": sharedImport,
            "UC": ucPascal,
            "A": aggregate.name,
            "AGG_ID_NAME": aggIdName,
            "INPUT_FIELDS": inputFields,
            "INIT_PARAMS_MID": initParamsMid,
            "INIT_ASSIGNMENTS": initAssignments,
        ]).output
    }

    // MARK: - Enum DTO renderer

    private static func renderEnumMapper(dto: DtoSpec, sharedImport: String) throws -> String {
        let template = try TemplateLoader.loadTemplate(name: "Api/DtoEnumMapper.swift", ext: "template")
        let domainType = domainTypeName(for: dto)
        // Use dto.cases if present, fallback to dto.fields.map(\.name) for legacy compatibility
        let caseList: [String] = dto.cases.isEmpty
            ? dto.fields.map(\.name)
            : dto.cases
        let fromDomain: String = caseList
            .map { "        case .\($0): self = .\($0)" }
            .joined(separator: "\n")
        let toDomain: String = caseList
            .map { "        case .\($0): self = .\($0)" }
            .joined(separator: "\n")

        return TemplateRenderer.render(template: template, vars: [
            "SharedImport": sharedImport,
            "DtoTypeName": dto.name,
            "DomainTypeName": domainType,
            "ENUM_FROM_DOMAIN_CASES": fromDomain,
            "ENUM_TO_DOMAIN_CASES": toDomain,
        ]).output
    }

    // MARK: - Struct DTO renderer

    private static func renderStructMapper(dto: DtoSpec, sharedImport: String) throws -> String {
        let template = try TemplateLoader.loadTemplate(name: "Api/DtoStructMapper.swift", ext: "template")
        let domainType = domainTypeName(for: dto)
        let fromDomain: String = dto.fields
            .map { "        self.\($0.name) = domain.\($0.name)" }
            .joined(separator: "\n")

        return TemplateRenderer.render(template: template, vars: [
            "SharedImport": sharedImport,
            "DtoTypeName": dto.name,
            "DomainTypeName": domainType,
            "STRUCT_FROM_DOMAIN_FIELDS": fromDomain,
        ]).output
    }
}
