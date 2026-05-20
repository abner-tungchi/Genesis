import XCTest
@testable import GenesisCore

final class BusinessDocRendererTests: XCTestCase {
    private func loadIAMBundle() throws -> FullBundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("GenesisIntegrationTests/Fixtures/iam-bundle.json")
        return try BundleParser.parseFull(at: url)
    }

    func testTypedStructFallsBackToString() throws {
        // Phase 1.e: BusinessDocRenderer's idType lookup falls back to "String" when
        // AdapterApplier.resolveIdWrapperName returns nil (which it does for typedStruct deprecation).
        // config.md should render `IDType: String` (or no typed wrapper reference).
        let bundle = try loadIAMBundle()
        let typedAdapter = Adapter(
            adapterVersion: 1, schemaVersion: 1, contextName: "IAMContext", bundleId: nil,
            typeMapping: [:], customTypes: [],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .typedStruct, wrapper: "{Aggregate}ID")
        )
        let outputs = try BusinessDocRenderer.render(
            spec: bundle.aggregates[0],
            bundle: bundle,
            adapter: typedAdapter,
            contextName: "IAMContext",
            generatedDate: "2026-05-17"
        )
        let config = outputs.first { $0.path.hasSuffix("config.md") }!.content
        XCTAssertFalse(
            config.contains("UserAccessProfileID"),
            "BusinessDocRenderer must NOT render typed-struct wrapper post deprecation: \(config)"
        )
    }
}
