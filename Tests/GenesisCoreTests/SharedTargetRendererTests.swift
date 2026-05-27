import XCTest
@testable import GenesisCore

final class SharedTargetRendererTests: XCTestCase {
    private func loadIAMBundle() throws -> FullBundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("GenesisIntegrationTests/Fixtures/iam-bundle.json")
        return try BundleParser.parseFull(at: url)
    }

    func testTypedStructDoesNotEmitAutoWrapper() throws {
        // Phase 1.e: typedStruct deprecation removes the SharedTargetRenderer auto-wrapper branch
        // that Phase 1.c added. Even with idStrategy.typedStruct, NO {Aggregate}ID file is generated
        // unless the user explicitly adds it to customTypes.
        let bundle = try loadIAMBundle()
        let typedAdapter = Adapter(
            adapterVersion: 1, schemaVersion: 1, contextName: "IAMContext", bundleId: nil,
            typeMapping: [:], customTypes: [],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .typedStruct, wrapper: "{Aggregate}ID")
        )
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: typedAdapter)
        let outputs = try SharedTargetRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: typedAdapter,
            ownership: ownership
        )
        let paths = outputs.map { $0.path }
        XCTAssertFalse(
            paths.contains("Sources/IAMContextShared/UserAccessProfileID.swift"),
            "typedStruct must NOT auto-generate ID wrapper post Phase 1.e deprecation: \(paths)"
        )
    }

    func testExplicitCustomTypeStillEmitted() throws {
        // Regression: user-declared customTypes (not the typedStruct auto-wrapper) still emit normally.
        let bundle = try loadIAMBundle()
        let adapter = Adapter(
            adapterVersion: 1, schemaVersion: 1, contextName: "IAMContext", bundleId: nil,
            typeMapping: [:],
            customTypes: [CustomTypeSpec(name: "MyWrapper", kind: .identifier, underlying: "UUID", cases: nil)],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .direct, wrapper: nil)
        )
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try SharedTargetRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: adapter,
            ownership: ownership
        )
        let paths = outputs.map { $0.path }
        XCTAssertTrue(paths.contains("Sources/IAMContextShared/MyWrapper.swift"))
    }

    // MARK: - Phase 1.f: ContextShared infra files always emitted

    private func renderDefault(contextName: String = "IAMContext") throws -> [(path: String, content: String, role: String)] {
        let bundle = try loadIAMBundle()
        let adapter = Adapter.defaultFor(contextName: contextName)
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        return try SharedTargetRenderer.render(
            bundle: bundle,
            contextName: contextName,
            adapter: adapter,
            ownership: ownership
        )
    }

    func testInfraFilesAlwaysEmitted() throws {
        let outputs = try renderDefault()
        let paths = Set(outputs.map { $0.path })
        let dir = "Sources/IAMContextShared"
        let expected = [
            "\(dir)/ApplicationService.swift",
            "\(dir)/ContextError.swift",
            "\(dir)/Iso8601.swift",
            "\(dir)/InvalidDecimalStringError.swift",
            "\(dir)/ProjectionReadInconsistency.swift",
            "\(dir)/String+IsBlank.swift",
            "\(dir)/String+PascalCase.swift",
            "\(dir)/String+StrippingPrefix.swift",
            "\(dir)/README.md",
        ]
        for path in expected {
            XCTAssertTrue(paths.contains(path), "missing infra file: \(path)")
        }
    }

    func testInfraFilesEmittedWithoutDTOs() throws {
        // Bundle with no DTOs and no customTypes: infra still emit (universal).
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
        let adapter = Adapter.defaultFor(contextName: "IAMContext")
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: stripped, adapter: adapter)
        let outputs = try SharedTargetRenderer.render(
            bundle: stripped,
            contextName: "IAMContext",
            adapter: adapter,
            ownership: ownership
        )
        let paths = Set(outputs.map { $0.path })
        XCTAssertTrue(paths.contains("Sources/IAMContextShared/ApplicationService.swift"))
        XCTAssertTrue(paths.contains("Sources/IAMContextShared/ContextError.swift"))
        XCTAssertFalse(paths.contains("Sources/IAMContextShared/EmployeeStatus.swift"), "stripped bundle has no DTOs")
    }

    func testInfraFileContentApplicationService() throws {
        let outputs = try renderDefault()
        let asFile = outputs.first { $0.path.hasSuffix("ApplicationService.swift") }!
        XCTAssertTrue(asFile.content.contains("package protocol ApplicationService"))
        XCTAssertTrue(asFile.content.contains("associatedtype Input"))
        XCTAssertTrue(asFile.content.contains("associatedtype Output"))
        XCTAssertTrue(asFile.content.contains("func execute(input: Input)"))
    }

    func testInfraFileContentContextError() throws {
        let outputs = try renderDefault()
        let ceFile = outputs.first { $0.path.hasSuffix("ContextError.swift") }!
        XCTAssertTrue(ceFile.content.contains("package struct ContextError<ErrorType: Error & Equatable>"))
        XCTAssertTrue(ceFile.content.contains("package enum Source"))
        XCTAssertTrue(ceFile.content.contains("static func =="))
    }

    func testInfraFileContentIso8601NoTaipei() throws {
        let outputs = try renderDefault()
        let isoFile = outputs.first { $0.path.hasSuffix("Iso8601.swift") }!
        XCTAssertFalse(isoFile.content.contains("TimeZoneConstants"))
        XCTAssertFalse(isoFile.content.contains("Calendar.taipei"))
        XCTAssertFalse(isoFile.content.contains("Asia/Taipei"))
        XCTAssertTrue(isoFile.content.contains("package struct Iso8601ParsingError"))
        XCTAssertTrue(isoFile.content.contains("package static func parseIso8601"))
        XCTAssertTrue(isoFile.content.contains(".gmt"))
    }

    func testInfraFileReadmeHasContextPlaceholder() throws {
        let outputs = try renderDefault(contextName: "IAMContext")
        let readme = outputs.first { $0.path.hasSuffix("README.md") }!
        XCTAssertTrue(readme.content.contains("IAMContext"), "ContextName placeholder must be substituted")
        XCTAssertTrue(readme.content.contains("0.1.0-phase1k"), "GenesisVersion placeholder must be substituted")
        XCTAssertFalse(readme.content.contains("{ContextName}"), "unresolved placeholder: \(readme.content)")
        XCTAssertFalse(readme.content.contains("{GenesisVersion}"), "unresolved placeholder")
        XCTAssertFalse(readme.content.contains("{Date}"), "unresolved placeholder")
    }

    func testInfraRoleIsSharedInfra() throws {
        let outputs = try renderDefault()
        let infraNames: Set<String> = [
            "ApplicationService.swift", "ContextError.swift", "Iso8601.swift",
            "InvalidDecimalStringError.swift", "ProjectionReadInconsistency.swift",
            "String+IsBlank.swift", "String+PascalCase.swift", "String+StrippingPrefix.swift",
            "README.md",
        ]
        let allInfraRole = outputs.filter { output in
            let name = (output.path as NSString).lastPathComponent
            return infraNames.contains(name)
        }
        XCTAssertEqual(allInfraRole.count, 9, "expected 9 infra files; got \(allInfraRole.map { $0.path })")
        for output in allInfraRole {
            XCTAssertEqual(output.role, "sharedInfra", "wrong role for \(output.path): \(output.role)")
        }
    }
}
