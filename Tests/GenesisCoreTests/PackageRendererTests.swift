import XCTest
@testable import GenesisCore

final class PackageRendererTests: XCTestCase {
    private func loadIAMBundle() throws -> FullBundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("GenesisIntegrationTests/Fixtures/iam-bundle.json")
        return try BundleParser.parseFull(at: url)
    }

    private var defaultAdapter: Adapter { .defaultFor(contextName: "IAMContext") }

    func testRenderHasPerAggregateProductAndTarget() throws {
        let bundle = try loadIAMBundle()
        let result = try PackageRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            genesisVersion: "0.1.0-test",
            adapter: defaultAdapter
        )
        XCTAssertEqual(result.path, "Package.swift")
        XCTAssertTrue(result.content.contains("name: \"IAMContext\""))
        XCTAssertTrue(result.content.contains(".library(name: \"UserAccessProfileAggregate\""))
        XCTAssertTrue(result.content.contains(".target("))
        XCTAssertTrue(result.content.contains("name: \"UserAccessProfileAggregate\""))
        XCTAssertTrue(result.content.contains("DomainEventGeneratorPlugin"))
        XCTAssertTrue(result.content.contains("from: \"0.3.0\""))
        XCTAssertTrue(result.content.contains("gradyzhuo/swift-ddd-kit"))
    }

    func testRenderIncludesSharedTargetWhenDtosExist() throws {
        let bundle = try loadIAMBundle()
        let result = try PackageRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            genesisVersion: "0.1.0-test",
            adapter: defaultAdapter
        )
        XCTAssertTrue(result.content.contains(".library(name: \"IAMContextShared\""))
        XCTAssertTrue(result.content.contains("name: \"IAMContextShared\""))
        XCTAssertTrue(
            result.content.contains(".target(name: \"IAMContextShared\")"),
            "aggregate target must declare dependency on Shared"
        )
    }

    func testTestTargetIncluded() throws {
        let bundle = try loadIAMBundle()
        let result = try PackageRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            genesisVersion: "0.1.0-test",
            adapter: defaultAdapter
        )
        XCTAssertTrue(result.content.contains(".testTarget("))
        XCTAssertTrue(result.content.contains("name: \"IAMContextTests\""))
    }

    // MARK: - Phase 1.e additions

    func testRenderIncludesModelGeneratorPlugin() throws {
        let bundle = try loadIAMBundle()
        let result = try PackageRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            genesisVersion: "0.1.0-test",
            adapter: defaultAdapter
        )
        XCTAssertTrue(
            result.content.contains(".plugin(name: \"ModelGeneratorPlugin\", package: \"swift-ddd-kit\")"),
            "Phase 1.e: ModelGeneratorPlugin produces {A}AggregateProtocol; required for aggregate template conformance"
        )
    }

    func testSharedTargetEmittedEvenWithoutDtosOrCustomTypes() throws {
        // Phase 1.f: Shared target is universal — emitted regardless of bundle DTOs / customTypes
        // because ContextShared infra files (ApplicationService, ContextError, Iso8601, etc.) are
        // bootstrapped unconditionally.
        let bundle = try loadIAMBundle()
        let stripped = FullBundle(
            manifestVersion: bundle.manifestVersion,
            bundleId: bundle.bundleId,
            context: bundle.context,
            aggregates: bundle.aggregates,
            useCases: bundle.useCases,
            dtos: [],
            readModels: bundle.readModels
        )
        let typedAdapter = Adapter(
            adapterVersion: 1, schemaVersion: 1, contextName: "IAMContext", bundleId: nil,
            typeMapping: [:], customTypes: [],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .typedStruct, wrapper: "{Aggregate}ID")
        )
        let result = try PackageRenderer.render(
            bundle: stripped,
            contextName: "IAMContext",
            genesisVersion: "0.1.0-test",
            adapter: typedAdapter
        )
        XCTAssertTrue(
            result.content.contains(".library(name: \"IAMContextShared\""),
            "Phase 1.f: Shared target must always emit for infra files: \(result.content)"
        )
    }
}
