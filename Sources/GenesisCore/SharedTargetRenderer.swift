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

        let knownCustomTypes = bundle.dtoTypeNames.union(byName.keys)

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
            // Phase 1.l.1.1: scope-based routing for Cosmogony v19 DTOs.
            // When dto.scope is set explicitly, route to the scope-specific dir.
            // For legacy DTOs (scope=nil/contextShared), fall through to TypeOwnership routing.
            if let scopeRoute = try scopeBasedRoute(for: dto, bundle: bundle) {
                let rendered = try DtoRenderer.render(
                    dto: dto,
                    hostTarget: scopeRoute.hostTarget,
                    knownCustomTypes: knownCustomTypes,
                    adapter: adapter
                )
                outputs.append(rendered)
                // Phase 1.l.1.1: domain type co-emit when wire/domain split
                // (e.g. dto.name=EmployeeStatusDto, dto.domainTypeName=EmployeeStatus).
                // Emit a mirror file at aggregate root so aggregate state can reference it.
                if let domainEmit = try renderDomainTypeMirror(
                    for: dto,
                    aggregateName: scopeRoute.aggregateName,
                    knownCustomTypes: knownCustomTypes,
                    adapter: adapter
                ) {
                    outputs.append(domainEmit)
                }
                emittedNames.insert(dto.name)
                continue
            }

            // Legacy path: TypeOwnership routing (Phase 1.n)
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

    /// Phase 1.l.1.1: Cosmogony v19 scope-based routing.
    /// Returns nil for scope=nil / scope=contextShared (caller falls through to TypeOwnership routing).
    /// Returns the target host dir (relative to Sources/) when scope is aggregate / perUseCase / perReadModel.
    private static func scopeBasedRoute(
        for dto: DtoSpec,
        bundle: FullBundle
    ) throws -> (hostTarget: String, aggregateName: String?)? {
        switch dto.scope {
        case "aggregate":
            guard let aggRef = dto.aggregateRef, !aggRef.isEmpty else {
                throw GenesisError.bundleInvalid(
                    reason: "DTO '\(dto.name)': scope='aggregate' requires non-empty 'aggregateRef'"
                )
            }
            return ("\(aggRef)Aggregate/Adapter/Dto", aggRef)
        case "perUseCase":
            guard let ucRef = dto.useCaseRef, !ucRef.isEmpty else {
                throw GenesisError.bundleInvalid(
                    reason: "DTO '\(dto.name)': scope='perUseCase' requires non-empty 'useCaseRef'"
                )
            }
            guard let uc = bundle.useCases.first(where: { $0.useCase == ucRef }) else {
                throw GenesisError.bundleInvalid(
                    reason: "DTO '\(dto.name)': useCaseRef '\(ucRef)' doesn't match any useCase. "
                          + "Available: \(bundle.useCases.map(\.useCase))"
                )
            }
            let ucPascal = CaseTransformer.upperCamel(uc.useCase)
            return ("\(uc.aggregate)Aggregate/Adapter/\(ucPascal)", uc.aggregate)
        case "perReadModel":
            guard let rmRef = dto.readModelRef, !rmRef.isEmpty else {
                throw GenesisError.bundleInvalid(
                    reason: "DTO '\(dto.name)': scope='perReadModel' requires non-empty 'readModelRef'"
                )
            }
            // BundleParser already canonicalized readModelRef via dtoSpecRef cross-ref;
            // also case-insensitive match here so Cosmogony lowerCamelCase readModelRef
            // (e.g. "getPermissions") matches normalized readModel.name (e.g. "GetPermissions").
            guard let rm = bundle.readModels.first(where: {
                $0.name.lowercased() == rmRef.lowercased()
            }) else {
                throw GenesisError.bundleInvalid(
                    reason: "DTO '\(dto.name)': readModelRef '\(rmRef)' doesn't match any readModel. "
                          + "Available: \(bundle.readModels.map(\.name))"
                )
            }
            // Find aggregate root: prefer rm.aggregateRef, fallback to eventRefs[0].sourceAggregate
            let aggName: String
            if let ref = rm.aggregateRef, !ref.isEmpty {
                aggName = ref
            } else if let firstEvent = rm.eventRefs.first {
                aggName = firstEvent.sourceAggregate
            } else {
                throw GenesisError.bundleInvalid(
                    reason: "DTO '\(dto.name)': readModel '\(rm.name)' has no aggregateRef nor eventRefs; "
                          + "cannot determine projector dir"
                )
            }
            return ("\(aggName)Aggregate/Usecase/Projector/\(rm.name)", aggName)
        case "contextShared", nil:
            return nil  // fall through to TypeOwnership routing
        default:
            throw GenesisError.bundleInvalid(
                reason: "DTO '\(dto.name)': unknown scope '\(dto.scope ?? "")'. "
                      + "Expected one of: aggregate / perUseCase / perReadModel / contextShared"
            )
        }
    }

    /// Phase 1.l.1.1: when DTO has `domainTypeName != name` (wire/domain split,
    /// e.g. EmployeeStatusDto wraps domain EmployeeStatus), emit a mirror file
    /// at `<A>Aggregate/<DomainTypeName>.swift` carrying the same shape (enum cases /
    /// struct fields). Aggregate state references the domain type — must exist.
    /// Phase 1.p will add explicit mapper extensions; for now just structural mirror.
    private static func renderDomainTypeMirror(
        for dto: DtoSpec,
        aggregateName: String?,
        knownCustomTypes: Set<String>,
        adapter: Adapter
    ) throws -> (String, String, String)? {
        guard let agg = aggregateName, !agg.isEmpty else { return nil }
        guard let domainName = dto.domainTypeName, !domainName.isEmpty, domainName != dto.name else { return nil }
        // Build a synthetic DtoSpec for the domain type (same fields/cases, different name)
        let domainDto = DtoSpec(
            dtoSpecId: dto.dtoSpecId + "-domain",
            name: domainName,
            description: dto.description,
            fields: dto.fields,
            dtoKind: dto.dtoKind,
            cases: dto.cases,
            domainTypeName: nil,
            isContextShared: nil,
            aggregateRef: nil,
            scope: nil,
            usage: nil,
            useCaseRef: nil,
            readModelRef: nil
        )
        return try DtoRenderer.render(
            dto: domainDto,
            hostTarget: "\(agg)Aggregate",
            knownCustomTypes: knownCustomTypes,
            adapter: adapter
        )
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
