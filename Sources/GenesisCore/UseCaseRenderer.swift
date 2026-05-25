import Foundation

public enum UseCaseRenderer {
    /// `sharedImport` is the optional `import {Ctx}Shared` line (empty when no Shared target exists);
    /// passed through to templates whose generated Swift may reference DTO / customType identifiers
    /// (Input fields, CommandExtension param/event types).
    public static func render(
        useCase: UseCaseSpec,
        bundle: FullBundle,
        adapter: Adapter,
        sharedImport: String = ""
    ) throws -> [(path: String, content: String, role: String)] {
        let ucName = CaseTransformer.upperCamel(useCase.useCase)
        let ucCamel = CaseTransformer.lowerCamel(useCase.useCase)
        let aggregate = useCase.aggregate
        let eventTypeName = CaseTransformer.upperCamel(useCase.emittedEvent)
        let knownCustomTypes = Set(bundle.dtos.map { $0.name } + adapter.customTypes.map { $0.name })

        let inputDir = "Sources/\(aggregate)Aggregate/Usecase/Port/In/\(ucName)"

        // Phase 1.l: lookup aggregate.identityName to auto-inject aggId field into UsecaseInput (OC alignment).
        guard let agg = bundle.aggregates.first(where: { $0.aggregateSpecId == useCase.aggregateSpecId }) else {
            throw GenesisError.bundleInvalid(
                reason: "useCase '\(useCase.useCase)' aggregateSpecId '\(useCase.aggregateSpecId)' not found in bundle.aggregates"
            )
        }
        let aggIdName = agg.identityName

        var outputs: [(String, String, String)] = []

        outputs.append(try renderInput(
            uc: ucName, fields: useCase.input,
            aggIdName: aggIdName,
            adapter: adapter, knownCustomTypes: knownCustomTypes,
            sharedImport: sharedImport, dir: inputDir
        ))
        outputs.append(try renderOutput(uc: ucName, dir: inputDir))
        outputs.append(try renderUsecase(uc: ucName, aggregate: aggregate, sharedImport: sharedImport, dir: inputDir))
        outputs.append(try renderService(uc: ucName, aggregate: aggregate))
        outputs.append(try renderCommandExtension(
            uc: ucName,
            ucCamel: ucCamel,
            aggregate: aggregate,
            eventTypeName: eventTypeName,
            commandFields: useCase.input,
            adapter: adapter,
            knownCustomTypes: knownCustomTypes,
            sharedImport: sharedImport
        ))

        return outputs
    }

    private static func renderInput(
        uc: String,
        fields: [FieldSpec],
        aggIdName: String,
        adapter: Adapter,
        knownCustomTypes: Set<String>,
        sharedImport: String,
        dir: String
    ) throws -> (String, String, String) {
        // Phase 1.l (audit M4): canonical ordering — aggId first, business fields middle, operatorId last.
        // Filter dedupes user-supplied aggId/operatorId in useCase.input[] to avoid double-emit.
        let businessFields = fields.filter { $0.name != aggIdName && $0.name != "operatorId" }
        let aggIdField = FieldSpec(name: aggIdName, rawType: "String")
        let operatorIdField = FieldSpec(name: "operatorId", rawType: "String")
        let canonicalFields = [aggIdField] + businessFields + [operatorIdField]

        var decls: [String] = []
        var initParamsParts: [String] = []
        var assignments: [String] = []
        for field in canonicalFields {
            let resolved = try SwiftTypeResolver.resolve(
                rawType: field.rawType, knownCustomTypes: knownCustomTypes, adapter: adapter
            )
            decls.append("    package let \(field.name): \(resolved)")
            initParamsParts.append("\(field.name): \(resolved)")
            assignments.append("        self.\(field.name) = \(field.name)")
        }

        let template = try TemplateLoader.loadTemplate(name: "UsecaseInput.swift", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "UC": uc,
                "SharedImport": sharedImport,
                "InputFieldDecls": decls.joined(separator: "\n"),
                "InitParams": initParamsParts.joined(separator: ", "),
                "InitAssignments": assignments.joined(separator: "\n"),
            ]
        )
        return ("\(dir)/\(uc)Input.swift", rendered.output, "usecaseInput")
    }

    private static func renderOutput(uc: String, dir: String) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "UsecaseOutput.swift", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: ["UC": uc])
        return ("\(dir)/\(uc)Output.swift", rendered.output, "usecaseOutput")
    }

    private static func renderUsecase(uc: String, aggregate: String, sharedImport: String, dir: String) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "Usecase.swift", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "UC": uc,
                "Aggregate": aggregate,
                "useCaseCamelCase": CaseTransformer.lowerCamel(uc),
                "SharedImport": sharedImport,
            ]
        )
        return ("\(dir)/\(uc)Usecase.swift", rendered.output, "usecase")
    }

    private static func renderService(uc: String, aggregate: String) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "Service.swift", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "UC": uc,
                "Aggregate": aggregate,
            ]
        )
        let path = "Sources/\(aggregate)Aggregate/Usecase/Service/\(uc)Service.swift"
        return (path, rendered.output, "service")
    }

    private static func renderCommandExtension(
        uc: String,
        ucCamel: String,
        aggregate: String,
        eventTypeName: String,
        commandFields: [FieldSpec],
        adapter: Adapter,
        knownCustomTypes: Set<String>,
        sharedImport: String
    ) throws -> (String, String, String) {
        var paramParts: [String] = []
        for field in commandFields {
            let resolved = try SwiftTypeResolver.resolve(
                rawType: field.rawType, knownCustomTypes: knownCustomTypes, adapter: adapter
            )
            paramParts.append("\(field.name): \(resolved)")
        }
        let commandParams = paramParts.joined(separator: ", ")

        let template = try TemplateLoader.loadTemplate(name: "CommandExtension.swift", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "Aggregate": aggregate,
                "SharedImport": sharedImport,
                "useCaseCamelCase": ucCamel,
                "CommandParams": commandParams,
                "EventTypeName": eventTypeName,
            ]
        )
        let path = "Sources/\(aggregate)Aggregate/Entity/Commands/\(aggregate)+\(uc).swift"
        return (path, rendered.output, "commandExtension")
    }
}
