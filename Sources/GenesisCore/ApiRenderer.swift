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
        existingPaths: Set<String> = [],
        ownership: [String: TypeOwnership]
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
                sharedImport: sharedImport,
                bundle: bundle
            )
            outputs.append((asPath, content, "applicationService"))
        }

        // --- Per-DTO mapper files (per-aggregate only; context-shared handled by SharedTargetRenderer) ---
        for dto in bundle.dtos {
            // Phase 1.l.1.1: scope-explicit DTOs (aggregate / perUseCase / perReadModel) are
            // handled by SharedTargetRenderer scope routing. ApiRenderer only handles legacy
            // ownership-routed DTOs (scope nil) AND scope=contextShared.
            if let scope = dto.scope, scope != "contextShared" { continue }
            guard case .ownedBy(let aggName) = ownership[dto.name] else { continue }
            let dtoKind = resolveDtoKind(dto)
            if dtoKind == "union" {
                // Defer Phase 1.i.2 — skip with no emit
                continue
            }
            // Phase 1.o.1 F6: identity-mapper skip — when dto.name == resolved domain type name,
            // both extensions in the mapper template land on the same Swift type, producing two
            // `init(from: <Name>)` declarations → "invalid redeclaration". Convention: use `Dto`
            // suffix (or explicit `domainTypeName`) when a wire/domain split is wanted.
            if dto.name == domainTypeName(for: dto) { continue }
            let mapperPath = "Sources/\(aggName)Aggregate/Adapter/Dto/\(dto.name)+Domain.swift"
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
        sharedImport: String,
        bundle: FullBundle
    ) throws -> String {
        let template = try TemplateLoader.loadTemplate(name: "Api/ApplicationService.swift", ext: "template")
        let aggIdName = aggregate.identityName

        // Filter Service Input: exclude operatorId (HTTP transport metadata) and aggregate ID (positional)
        let middleFields = useCase.input.filter { $0.name != "operatorId" && $0.name != aggIdName }

        // Phase 1.p D13: build domainTypeName → DTO swap lookup for usage ∈ {request, both} DTOs.
        // When AS Input field rawType matches a request DTO's domainTypeName, swap to DTO type.
        // (Domain UseCase Input keeps domain types; AS Input is wire-side, uses Dto types per OC.)
        let dtoSwapMap: [String: String] = bundle.dtos.reduce(into: [:]) { acc, dto in
            guard let scope = dto.scope, scope != "contextShared" else { return }
            let usage = dto.usage ?? "both"
            guard usage == "request" || usage == "both" else { return }
            guard let domain = dto.domainTypeName, !domain.isEmpty else { return }
            acc[domain] = dto.name
        }

        // Resolve raw bundle types (e.g. "Array[String]" → "[String]") via SwiftTypeResolver per existing convention.
        // Phase 1.p: if rawType maps to a wire DTO via swap map, use DTO name directly (skip resolve).
        let knownTypes = Set<String>()  // ApiRenderer doesn't track custom types; bundle.dtos[] resolved separately
        let resolvedFields = try middleFields.map { f -> (String, String) in
            if let dtoName = dtoSwapMap[f.rawType] {
                return (f.name, dtoName)  // Phase 1.p D13: swapped to wire DTO type
            }
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

        // Phase 1.j: emit `extension {UC}ApplicationServiceInput { init(from payload:) throws { ... } }`
        // in same AS file when any non-aggId non-operatorId field resolves to Date / Date?.
        let payloadInitExtension = renderPayloadInitExtension(
            ucPascal: ucPascal,
            aggIdName: aggIdName,
            resolvedFields: resolvedFields
        )

        return TemplateRenderer.render(template: template, vars: [
            "SharedImport": sharedImport,
            "UC": ucPascal,
            "A": aggregate.name,
            "AGG_ID_NAME": aggIdName,
            "INPUT_FIELDS": inputFields,
            "INIT_PARAMS_MID": initParamsMid,
            "INIT_ASSIGNMENTS": initAssignments,
            "PAYLOAD_INIT_EXTENSION": payloadInitExtension,
        ]).output
    }

    // MARK: - Phase 1.j: Variant B-Date init(from payload:) extension

    /// Returns true iff any resolved field type equals "Date" or "Date?" (Variant B-Date trigger).
    private static func hasVariantBDate(resolvedFields: [(String, String)]) -> Bool {
        resolvedFields.contains { _, type in type == "Date" || type == "Date?" }
    }

    /// Emit the `extension {UC}ApplicationServiceInput { init(from payload:) throws { ... } }` block,
    /// OR empty string when no Date field (Variant A path stays unchanged).
    /// Each non-aggId non-operatorId field maps to:
    /// - plain → `<f>: payload.<f>,`
    /// - Date / Date? → `<f>: try Date.parseIso8601(payload.<f>),`
    ///   (Phase 1.f `parseIso8601` has String→Date + String?→Date? overloads; Swift auto-resolves.)
    private static func renderPayloadInitExtension(
        ucPascal: String,
        aggIdName: String,
        resolvedFields: [(String, String)]
    ) -> String {
        guard hasVariantBDate(resolvedFields: resolvedFields) else { return "" }
        let fieldLines: String = resolvedFields.map { name, type -> String in
            if type == "Date" || type == "Date?" {
                return "            \(name): try Date.parseIso8601(payload.\(name)),"
            }
            return "            \(name): payload.\(name),"
        }.joined(separator: "\n")

        return """
        extension \(ucPascal)ApplicationServiceInput {
            package init(
                from payload: Components.Schemas.\(ucPascal)Request,
                \(aggIdName): String,
                operatorId: String
            ) throws {
                self.init(
                    \(aggIdName): \(aggIdName),
        \(fieldLines)
                    operatorId: operatorId
                )
            }
        }

        """
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
