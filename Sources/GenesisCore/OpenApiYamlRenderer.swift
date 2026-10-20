import Foundation

/// Phase 1.i: openapi.yaml + openapi-generator-config.yaml emission per aggregate
/// (only when aggregate has at least 1 write UC).
///
/// Pure function of bundle.
public enum OpenApiYamlRenderer {

    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)] {
        var outputs: [(String, String, String)] = []

        for aggregate in bundle.aggregates {
            let writeUCs = bundle.useCases.filter {
                $0.aggregateSpecId == aggregate.aggregateSpecId && !ApiRenderer.isReadUseCase($0.useCase)
            }
            let presenters = bundle.presenters.filter { $0.aggregateRef == aggregate.name }
            guard !writeUCs.isEmpty || !presenters.isEmpty else { continue }

            // openapi.yaml (Phase 1.i write POSTs + Phase 1.k read GETs)
            let yamlPath = "Sources/\(aggregate.name)Aggregate/openapi.yaml"
            if !existingPaths.contains(yamlPath) {
                let yamlContent = try renderOpenApiYaml(
                    aggregate: aggregate,
                    writeUCs: writeUCs,
                    presenters: presenters,
                    contextName: contextName
                )
                outputs.append((yamlPath, yamlContent, "openapiYaml"))
            }

            // openapi-generator-config.yaml
            let cfgPath = "Sources/\(aggregate.name)Aggregate/openapi-generator-config.yaml"
            if !existingPaths.contains(cfgPath) {
                let cfgContent = try TemplateLoader.loadTemplate(
                    name: "Api/openapi-generator-config.yaml",
                    ext: "template"
                )
                outputs.append((cfgPath, cfgContent, "openapiGeneratorConfig"))
            }
        }

        // Phase 1.k.2: Context-level openapi.yaml + config (when bundle has cross-agg presenter)
        if PresenterPlacementResolver.hasContextLevelPresenter(bundle: bundle) {
            let contextPresenters = bundle.presenters.filter { $0.aggregateRef == "<context-level>" }
            let sourceAggs = PresenterPlacementResolver.contextSourceAggregates(bundle: bundle)
            let sourceAggSpecs = bundle.aggregates.filter { sourceAggs.contains($0.name) }

            let ctxYamlPath = "Sources/\(contextName)/openapi.yaml"
            if !existingPaths.contains(ctxYamlPath) {
                let ctxYamlContent = try renderContextOpenApiYaml(
                    contextName: contextName,
                    presenters: contextPresenters,
                    sourceAggregates: sourceAggSpecs
                )
                outputs.append((ctxYamlPath, ctxYamlContent, "contextOpenapiYaml"))
            }

            let ctxCfgPath = "Sources/\(contextName)/openapi-generator-config.yaml"
            if !existingPaths.contains(ctxCfgPath) {
                let cfgContent = try TemplateLoader.loadTemplate(
                    name: "Api/openapi-generator-config.yaml",
                    ext: "template"
                )
                outputs.append((ctxCfgPath, cfgContent, "contextOpenapiGeneratorConfig"))
            }
        }

        return outputs
    }

    private static func renderContextOpenApiYaml(
        contextName: String,
        presenters: [PresenterSpec],
        sourceAggregates: [AggregateSpec]
    ) throws -> String {
        let template = try TemplateLoader.loadTemplate(name: "Api/openapi-context.yaml", ext: "template")

        var pathOps: [String] = []
        var pathParamNames: Set<String> = []
        for presenter in presenters {
            let ucCamel = CaseTransformer.lowerCamel(presenter.name)
            let pathParamName = presenter.input.fields.first?.name ?? "id"
            pathParamNames.insert(pathParamName)

            var op: [String] = []
            op.append("  \(presenter.endpoint.path):")
            op.append("    get:")
            op.append("      operationId: \(ucCamel)")
            op.append("      description: 'TODO: describe \(presenter.name)'")
            op.append("      parameters:")
            op.append("        - $ref: '#/components/parameters/\(pathParamName)'")
            op.append("      responses:")
            op.append("        '200':")
            op.append("          description: 'success'")
            op.append("          content:")
            op.append("            application/json:")
            op.append("              schema:")
            op.append(contentsOf: presenterResponseSchemaLines(for: presenter.output, indent: 16))
            op.append("        '404':")
            op.append("          $ref: '#/components/responses/NotFoundError'")
            op.append("        '422':")
            op.append("          $ref: '#/components/responses/UnprocessableEntityError'")
            op.append("        '503':")
            op.append("          $ref: '#/components/responses/ServiceUnavailableError'")
            pathOps.append(op.joined(separator: "\n"))
        }

        // audit M6: context-level params are presenter-only — no operatorId, no aggregate-identity {A}Id
        var parameterLines: [String] = []
        for pname in pathParamNames.sorted() {
            parameterLines.append("    \(pname):")
            parameterLines.append("      name: \(pname)")
            parameterLines.append("      in: path")
            parameterLines.append("      required: true")
            parameterLines.append("      schema:")
            parameterLines.append("        type: string")
        }
        let parametersBlock = parameterLines.joined(separator: "\n")

        // Domain error cases: union of all source-aggregate errorCodes (for context ApiError enum).
        // Required so context-level ApiComponents per-agg overloads' `case .x: self = .x` compiles.
        var seenCases: Set<String> = []
        var domainCases: [String] = []
        for agg in sourceAggregates.sorted(by: { $0.name < $1.name }) {
            for inv in agg.invariants where !seenCases.contains(inv.errorCode) {
                seenCases.insert(inv.errorCode)
                domainCases.append("        - \(inv.errorCode)")
            }
        }

        return TemplateRenderer.render(template: template, vars: [
            "ContextName": contextName,
            "Context": contextName,
            "PATH_OPERATIONS": pathOps.joined(separator: "\n"),
            "PARAMETERS_BLOCK": parametersBlock,
            "DOMAIN_ERROR_CASES": domainCases.joined(separator: "\n"),
        ]).output
    }

    private static func renderOpenApiYaml(
        aggregate: AggregateSpec,
        writeUCs: [UseCaseSpec],
        presenters: [PresenterSpec],
        contextName: String
    ) throws -> String {
        let template = try TemplateLoader.loadTemplate(name: "Api/openapi.yaml", ext: "template")

        let aggIdName = aggregate.identityName
        let aggKebab = kebabCase(aggregate.name)

        // Build path operations + request schemas — explicit indentation, no multi-line literals
        var pathOps: [String] = []
        var requestSchemas: [String] = []
        for uc in writeUCs {
            let ucPascal = CaseTransformer.upperCamel(uc.useCase)
            let ucCamel = uc.useCase
            let ucKebab = kebabCase(uc.useCase)

            var op: [String] = []
            op.append("  /\(aggKebab)/{\(aggIdName)}/\(ucKebab):")
            op.append("    post:")
            op.append("      operationId: \(ucCamel)")
            op.append("      description: 'TODO: describe \(ucCamel)'")
            op.append("      parameters:")
            op.append("        - $ref: '#/components/parameters/\(aggIdName)'")
            op.append("        - $ref: '#/components/parameters/operatorId'")
            op.append("      requestBody:")
            op.append("        required: true")
            op.append("        content:")
            op.append("          application/json:")
            op.append("            schema:")
            op.append("              $ref: '#/components/schemas/\(ucPascal)Request'")
            op.append("      responses:")
            op.append("        '200':")
            op.append("          description: 'success'")
            op.append("          content:")
            op.append("            application/json:")
            op.append("              schema:")
            op.append("                $ref: '#/components/schemas/\(aggregate.name)Id'")
            op.append("        '404':")
            op.append("          $ref: '#/components/responses/NotFoundError'")
            op.append("        '422':")
            op.append("          $ref: '#/components/responses/UnprocessableEntityError'")
            op.append("        '503':")
            op.append("          $ref: '#/components/responses/ServiceUnavailableError'")
            pathOps.append(op.joined(separator: "\n"))

            // Build request schema — schema at 4-space (under "  schemas:" at 2-space level)
            let inputFields = uc.input.filter { $0.name != "operatorId" && $0.name != aggIdName }
            var rs: [String] = []
            rs.append("    \(ucPascal)Request:")
            rs.append("      type: object")
            if !inputFields.isEmpty {
                rs.append("      required:")
                for field in inputFields {
                    rs.append("        - \(field.name)")
                }
                rs.append("      properties:")
                for field in inputFields {
                    rs.append("        \(field.name):")
                    // Phase 1.t.2 / PA-F5: collection fields (Array[X] / Set[X] / [X] / Array<X> / Set<X>) must
                    // emit `type: array` + `items:` — previously fell through yamlType's fallback to `type: string`
                    // (yamlType only recognized angle-bracket Array<>/Set<>, not Cosmogony's bracket Array[]/Set[]),
                    // which broke /api fill (payload.<f>: String vs AS Input [X]) and the generated API contract.
                    if let elementType = collectionElementType(of: field.rawType) {
                        rs.append("          type: array")
                        rs.append("          items:")
                        rs.append("            type: \(yamlType(for: elementType))")
                    } else {
                        rs.append("          type: \(yamlType(for: field.rawType))")
                    }
                }
            }
            requestSchemas.append(rs.joined(separator: "\n"))
        }

        // Phase 1.k: presenter GET endpoints
        for presenter in presenters {
            let ucCamel = CaseTransformer.lowerCamel(presenter.name)
            let pathParamName = presenter.input.fields.first?.name ?? aggregate.identityName

            var op: [String] = []
            // Use presenter.endpoint.path (already pre-set by /presenter skill)
            op.append("  \(presenter.endpoint.path):")
            op.append("    get:")
            op.append("      operationId: \(ucCamel)")
            op.append("      description: 'TODO: describe \(presenter.name)'")
            op.append("      parameters:")
            op.append("        - $ref: '#/components/parameters/\(pathParamName)'")
            op.append("      responses:")
            op.append("        '200':")
            op.append("          description: 'success'")
            op.append("          content:")
            op.append("            application/json:")
            op.append("              schema:")
            // Response schema per output.kind
            op.append(contentsOf: presenterResponseSchemaLines(for: presenter.output, indent: 16))
            op.append("        '404':")
            op.append("          $ref: '#/components/responses/NotFoundError'")
            op.append("        '422':")
            op.append("          $ref: '#/components/responses/UnprocessableEntityError'")
            op.append("        '503':")
            op.append("          $ref: '#/components/responses/ServiceUnavailableError'")
            pathOps.append(op.joined(separator: "\n"))
        }

        // Domain error cases
        let domainErrorCases: [String] = aggregate.invariants
            .map(\.errorCode)
            .reduce(into: [String]()) { acc, code in
                if !acc.contains(code) { acc.append(code) }
            }
            .map { "        - \($0)" }

        // Phase 1.k: build dynamic parameters block — collect unique path/header param names
        // from write UCs (path = aggIdName) + presenters (path = first input field name)
        var pathParamNames: Set<String> = [aggIdName]  // always present for write UCs
        for presenter in presenters {
            if let first = presenter.input.fields.first {
                pathParamNames.insert(first.name)
            }
        }
        var parameterLines: [String] = []
        for pname in pathParamNames.sorted() {
            parameterLines.append("    \(pname):")
            parameterLines.append("      name: \(pname)")
            parameterLines.append("      in: path")
            parameterLines.append("      required: true")
            parameterLines.append("      schema:")
            parameterLines.append("        type: string")
        }
        // operatorId header — only needed for write UCs (per OC convention)
        if !writeUCs.isEmpty {
            parameterLines.append("    operatorId:")
            parameterLines.append("      name: operatorId")
            parameterLines.append("      in: header")
            parameterLines.append("      required: true")
            parameterLines.append("      schema:")
            parameterLines.append("        type: string")
        }
        let parametersBlock = parameterLines.joined(separator: "\n")

        let vars: [String: String] = [
            "ContextName": contextName,
            "AggregateName": aggregate.name,
            "A": aggregate.name,
            "aggIdName": aggIdName,
            "PATH_OPERATIONS": pathOps.joined(separator: "\n"),
            "DOMAIN_ERROR_CASES": domainErrorCases.joined(separator: "\n"),
            "REQUEST_SCHEMAS": requestSchemas.joined(separator: "\n"),
            "PARAMETERS_BLOCK": parametersBlock,
        ]
        return TemplateRenderer.render(template: template, vars: vars).output
    }

    // MARK: - Helpers

    static func kebabCase(_ s: String) -> String {
        var result = ""
        for (i, ch) in s.enumerated() {
            if ch.isUppercase && i > 0 {
                result.append("-")
            }
            result.append(Character(ch.lowercased()))
        }
        return result
    }

    /// Swift primitive element types that have no `components/schemas` entry — they must be inlined
    /// (`type: string`), never `$ref`'d (swift-openapi-generator fails on a dangling `$ref`).
    private static let primitiveSchemaTypes: Set<String> = [
        "String", "Int", "Int64", "UInt", "UInt64", "Bool", "Decimal", "Date", "Double", "Float",
    ]

    /// Schema lines for a response element type: primitives and nested collections are inlined, any other
    /// (custom / DTO) type is a `$ref` to `components/schemas`.
    static func schemaLines(forElementType type: String, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        let t = type.trimmingCharacters(in: .whitespaces)
        if let inner = collectionElementType(of: t) {
            return ["\(pad)type: array", "\(pad)items:"] + schemaLines(forElementType: inner, indent: indent + 2)
        }
        let base = t.replacingOccurrences(of: "?", with: "")
        if primitiveSchemaTypes.contains(base) {
            switch base {
            case "Double", "Float": return ["\(pad)type: number"]
            default: return ["\(pad)type: \(yamlType(for: base))"]
            }
        }
        return ["\(pad)$ref: '#/components/schemas/\(base)'"]
    }

    /// Presenter GET 200-response schema lines (under `schema:`), per output kind.
    static func presenterResponseSchemaLines(for output: PresenterOutput, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        switch output.kind {
        case .array:
            return ["\(pad)type: array", "\(pad)items:"] + schemaLines(forElementType: output.elementType, indent: indent + 2)
        case .single:
            return schemaLines(forElementType: output.elementType, indent: indent)
        case .scalar:
            return ["\(pad)type: \(yamlType(for: output.elementType))"]
        }
    }

    static func yamlType(for swiftType: String) -> String {
        let t = swiftType.trimmingCharacters(in: .whitespaces)
        // Phase 1.t.2 / PA-F5: recognize bracket notation (Array[X]/Set[X], Cosmogony schema) in addition
        // to angle (Array<X>/Set<X>) and plain [X], so collections never fall through to the string fallback.
        if collectionElementType(of: t) != nil {
            return "array"
        }
        let baseType = t.replacingOccurrences(of: "?", with: "")
        switch baseType {
        case "String": return "string"
        case "Int", "Int64", "UInt", "UInt64": return "integer"
        case "Bool": return "boolean"
        case "Decimal": return "string"     // v1 simplification (DecimalAmount $ref defer)
        case "Date": return "string"        // plugin 1.x limit — no format: date-time
        default: return "string"            // fallback
        }
    }

    /// Phase 1.t.2 / PA-F5: element Swift type of a collection, or nil if not a collection.
    /// Handles Cosmogony bracket notation (Array[X] / Set[X]) + angle (Array<X> / Set<X>) + plain [X].
    static func collectionElementType(of swiftType: String) -> String? {
        let t = swiftType.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "?", with: "")
        for prefix in ["Array<", "Set<"] where t.hasPrefix(prefix) && t.hasSuffix(">") {
            return String(t.dropFirst(prefix.count).dropLast())
        }
        for prefix in ["Array[", "Set["] where t.hasPrefix(prefix) && t.hasSuffix("]") {
            return String(t.dropFirst(prefix.count).dropLast())
        }
        if t.hasPrefix("[") && t.hasSuffix("]") {
            return String(t.dropFirst().dropLast())
        }
        return nil
    }
}
