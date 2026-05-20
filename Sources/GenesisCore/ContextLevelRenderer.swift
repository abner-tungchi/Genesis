import Foundation
import Yams

public enum ContextLevelRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        adapterProvided: Bool
    ) throws -> [(path: String, content: String, role: String)] {
        var outputs: [(String, String, String)] = []

        outputs.append(try renderConventionsApi(contextName: contextName, bundle: bundle))

        if !adapterProvided {
            outputs.append(try renderStarterAdapter(contextName: contextName, adapter: adapter))
        }

        return outputs
    }

    private static func renderConventionsApi(contextName: String, bundle: FullBundle) throws -> (String, String, String) {
        let template = try TemplateLoader.loadTemplate(name: "Conventions/api.md", ext: "template")
        let rendered = TemplateRenderer.render(
            template: template,
            vars: [
                "ContextName": contextName,
                "BundleId": bundle.bundleId,
            ]
        )
        return (".ai/conventions/api.md", rendered.output, "contextDoc")
    }

    private static func renderStarterAdapter(
        contextName: String,
        adapter: Adapter
    ) throws -> (String, String, String) {
        let starter = StarterAdapterPayload(
            adapterVersion: adapter.adapterVersion,
            schemaVersion: adapter.schemaVersion,
            contextName: adapter.contextName,
            typeMapping: adapter.typeMapping.isEmpty ? nil : adapter.typeMapping,
            customTypes: adapter.customTypes.isEmpty ? nil : adapter.customTypes.map(StarterCustomType.init),
            createdEventOverrides: adapter.createdEventOverrides.isEmpty ? nil : adapter.createdEventOverrides,
            aggregateSplit: StarterAggregateSplit(
                strategy: adapter.aggregateSplit.strategy,
                rootMap: adapter.aggregateSplit.rootMap.isEmpty ? nil : adapter.aggregateSplit.rootMap
            ),
            idStrategy: StarterIdStrategy(
                kind: adapter.idStrategy.kind.rawValue,
                wrapper: adapter.idStrategy.wrapper
            )
        )
        let yaml: String
        do {
            yaml = try YAMLEncoder().encode(starter)
        } catch {
            throw GenesisError.fileSystemFailed(
                operation: "encode starter adapter yaml",
                underlying: error.localizedDescription
            )
        }
        return (".ai/contexts/\(contextName)/swift-adapter.yaml", yaml, "contextDoc")
    }

    private struct StarterAdapterPayload: Encodable {
        let adapterVersion: Int
        let schemaVersion: Int
        let contextName: String
        let typeMapping: [String: String]?
        let customTypes: [StarterCustomType]?
        let createdEventOverrides: [String: String]?
        let aggregateSplit: StarterAggregateSplit
        let idStrategy: StarterIdStrategy
    }

    private struct StarterCustomType: Encodable {
        let name: String
        let kind: String
        let underlying: String?
        let cases: [String]?

        init(from spec: CustomTypeSpec) {
            self.name = spec.name
            self.kind = spec.kind.rawValue
            self.underlying = spec.underlying
            self.cases = spec.cases
        }
    }

    private struct StarterAggregateSplit: Encodable {
        let strategy: String
        let rootMap: [String: String]?
    }

    private struct StarterIdStrategy: Encodable {
        let kind: String
        let wrapper: String?
    }
}
