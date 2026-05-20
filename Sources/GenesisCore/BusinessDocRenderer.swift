import Foundation

public enum BusinessDocRenderer {
    public static func render(
        spec: AggregateSpec,
        bundle: FullBundle,
        adapter: Adapter,
        contextName: String,
        generatedDate: String
    ) throws -> [(path: String, content: String, role: String)] {
        let docDir = ".ai/contexts/\(contextName)/\(spec.name)"
        let aggregateUseCases = bundle.useCases.filter { $0.aggregateSpecId == spec.aggregateSpecId }

        let baseVars: [String: String] = [
            "Aggregate": spec.name,
            "ContextName": contextName,
            "BundleId": bundle.bundleId,
            "GeneratedDate": generatedDate,
            "GenesisVersion": GenesisCoreVersion.current,
        ]

        var outputs: [(String, String, String)] = []

        outputs.append(try renderConfig(spec: spec, useCases: aggregateUseCases, adapter: adapter, baseVars: baseVars, dir: docDir))
        outputs.append(try renderCommands(spec: spec, useCases: aggregateUseCases, baseVars: baseVars, dir: docDir))
        outputs.append(try renderInvariants(spec: spec, baseVars: baseVars, dir: docDir))
        outputs.append(try renderErrors(spec: spec, baseVars: baseVars, dir: docDir))
        outputs.append(try renderApi(baseVars: baseVars, dir: docDir))
        outputs.append(try renderTestScenarios(spec: spec, useCases: aggregateUseCases, baseVars: baseVars, dir: docDir))
        outputs.append(try renderReference(baseVars: baseVars, dir: docDir))

        // notes/README.md + per-UC notes/{useCase}.md
        outputs.append(try renderNotesReadme(baseVars: baseVars, dir: docDir))
        for uc in aggregateUseCases {
            outputs.append(try renderNoteForUseCase(uc: uc, baseVars: baseVars, dir: docDir))
        }

        return outputs
    }

    // MARK: - Per-file renderers

    private static func renderConfig(
        spec: AggregateSpec,
        useCases: [UseCaseSpec],
        adapter: Adapter,
        baseVars: [String: String],
        dir: String
    ) throws -> (String, String, String) {
        // Phase 1.e: typedStruct deprecated; always falls back to String
        // (resolveIdWrapperName returns nil for typedStruct + emits warning)
        let idType = AdapterApplier.resolveIdWrapperName(for: spec, adapter: adapter) ?? "String"
        var vars = baseVars
        vars["IdentityName"] = spec.identityName
        vars["IDType"] = idType
        vars["UseCaseCount"] = String(useCases.count)
        vars["AggregateSpecId"] = spec.aggregateSpecId
        let template = try TemplateLoader.loadTemplate(name: "BusinessDoc/config.md", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: vars)
        return ("\(dir)/config.md", rendered.output, "businessDoc")
    }

    private static func renderCommands(
        spec: AggregateSpec,
        useCases: [UseCaseSpec],
        baseVars: [String: String],
        dir: String
    ) throws -> (String, String, String) {
        var blocks: [String] = []
        for uc in useCases {
            blocks.append(renderCommandBlock(uc: uc))
        }
        var vars = baseVars
        vars["CommandBlocks"] = blocks.joined(separator: "\n")
        let template = try TemplateLoader.loadTemplate(name: "BusinessDoc/commands.md", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: vars)
        return ("\(dir)/commands.md", rendered.output, "businessDoc")
    }

    private static func renderCommandBlock(uc: UseCaseSpec) -> String {
        let inputLines = uc.input.isEmpty
            ? "_(no input fields)_"
            : uc.input.map { "- `\($0.name): \($0.rawType)`" }.joined(separator: "\n")
        let preLines = uc.preconditions.isEmpty
            ? "_(no preconditions in bundle)_"
            : uc.preconditions.map { "- \($0)" }.joined(separator: "\n")

        return """
        ## \(uc.useCase)

        **Input**:
        \(inputLines)

        **Preconditions** (from bundle):
        \(preLines)

        **Emits**: `\(uc.emittedEvent)` → see `event.yaml`

        **State transitions** (to be filled by `/usecase` skill):
        - _placeholder_

        ---
        """
    }

    private static func renderInvariants(
        spec: AggregateSpec,
        baseVars: [String: String],
        dir: String
    ) throws -> (String, String, String) {
        var blocks: [String] = []
        for inv in spec.invariants {
            blocks.append(renderInvariantBlock(inv: inv))
        }
        if blocks.isEmpty {
            blocks.append("_(no invariants declared in bundle)_")
        }
        var vars = baseVars
        vars["InvariantBlocks"] = blocks.joined(separator: "\n")
        let template = try TemplateLoader.loadTemplate(name: "BusinessDoc/invariants.md", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: vars)
        return ("\(dir)/invariants.md", rendered.output, "businessDoc")
    }

    private static func renderInvariantBlock(inv: InvariantSpec) -> String {
        let ruleLines = inv.rules.isEmpty
            ? "_(no rules listed in bundle)_"
            : inv.rules.map { "- when `\($0.when)`: `\($0.rule)`" }.joined(separator: "\n")
        return """
        ## \(inv.name)

        **Title**: \(inv.title.isEmpty ? "_(empty)_" : inv.title)
        **Error code**: `\(inv.errorCode)`
        **Status**: \(inv.status.isEmpty ? "_(empty)_" : inv.status)

        **Rules**:
        \(ruleLines)

        ---
        """
    }

    private static func renderErrors(
        spec: AggregateSpec,
        baseVars: [String: String],
        dir: String
    ) throws -> (String, String, String) {
        var seenCodes: Set<String> = []
        var blocks: [String] = []
        for inv in spec.invariants where seenCodes.insert(inv.errorCode).inserted {
            blocks.append("""
            ## `\(inv.errorCode)`

            **Title**: \(inv.title.isEmpty ? "_(empty)_" : inv.title)
            **HTTP status**: _(intentionally omitted — D17 says transport mapping lives in `api.md`)_

            ---
            """)
        }
        if blocks.isEmpty {
            blocks.append("_(no error codes declared in bundle)_")
        }
        var vars = baseVars
        vars["ErrorBlocks"] = blocks.joined(separator: "\n")
        let template = try TemplateLoader.loadTemplate(name: "BusinessDoc/errors.md", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: vars)
        return ("\(dir)/errors.md", rendered.output, "businessDoc")
    }

    private static func renderApi(baseVars: [String: String], dir: String) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "BusinessDoc/api.md", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: baseVars)
        return ("\(dir)/api.md", rendered.output, "businessDoc")
    }

    private static func renderTestScenarios(
        spec: AggregateSpec,
        useCases: [UseCaseSpec],
        baseVars: [String: String],
        dir: String
    ) throws -> (String, String, String) {
        var blocks: [String] = []
        for uc in useCases {
            blocks.append("""
            Scenario: \(uc.useCase)
              Given _(initial state placeholder)_
              When  \(uc.useCase)(\(uc.input.map { $0.name }.joined(separator: ", ")))
              Then  emits `\(uc.emittedEvent)`
            """)
        }
        for inv in spec.invariants {
            blocks.append("""
            Scenario: invariant \(inv.name)
              Given _(state violating \(inv.errorCode))_
              When  any command
              Then  throws `\(inv.errorCode)`
            """)
        }
        if blocks.isEmpty {
            blocks.append("_(no scenarios derivable from bundle)_")
        }
        var vars = baseVars
        vars["ScenarioBlocks"] = blocks.joined(separator: "\n\n")
        let template = try TemplateLoader.loadTemplate(name: "BusinessDoc/test-scenarios.md", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: vars)
        return ("\(dir)/test-scenarios.md", rendered.output, "businessDoc")
    }

    private static func renderReference(baseVars: [String: String], dir: String) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "BusinessDoc/reference.md", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: baseVars)
        return ("\(dir)/reference.md", rendered.output, "businessDoc")
    }

    private static func renderNotesReadme(baseVars: [String: String], dir: String) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "BusinessDoc/notes-README.md", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: baseVars)
        return ("\(dir)/notes/README.md", rendered.output, "businessDoc")
    }

    private static func renderNoteForUseCase(
        uc: UseCaseSpec,
        baseVars: [String: String],
        dir: String
    ) throws -> (String, String, String) {
        var vars = baseVars
        vars["UseCase"] = uc.useCase
        vars["EmittedEvent"] = uc.emittedEvent
        let template = try TemplateLoader.loadTemplate(name: "BusinessDoc/notes-usecase.md", ext: "template")
        let rendered = TemplateRenderer.render(template: template, vars: vars)
        return ("\(dir)/notes/\(uc.useCase).md", rendered.output, "businessDoc")
    }
}
