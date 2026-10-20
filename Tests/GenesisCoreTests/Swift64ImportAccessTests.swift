import XCTest
@testable import GenesisCore

/// Swift 6.4 rejects a module that mixes `package import Foundation.*` (emitted by swift-openapi-generator
/// when `accessModifier: package`) with plain `import Foundation` (our files, SwiftPM's resource_bundle_accessor,
/// DDDKit plugin outputs): "ambiguous implicit access level for import of 'Foundation'". Genesis therefore asks
/// the generator for `accessModifier: internal` (plain imports) and exposes a `package` forwarder for the
/// Server target. These tests lock that contract.
final class Swift64ImportAccessTests: XCTestCase {
    private func fixture(_ name: String) throws -> FullBundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("GenesisIntegrationTests/Fixtures/\(name)")
        return try BundleParser.parseFull(at: url)
    }

    private let adapter = Adapter.defaultFor(contextName: "IAMContext")

    func testOpenApiGeneratorConfigUsesInternalAccessModifier() throws {
        for name in ["iam-bundle.json", "iam-cross-agg-presenter-bundle.json"] {
            let outputs = try OpenApiYamlRenderer.render(bundle: try fixture(name), contextName: "IAMContext", adapter: adapter)
            let configs = outputs.filter { $0.path.hasSuffix("openapi-generator-config.yaml") }
            XCTAssertFalse(configs.isEmpty, name)
            for c in configs {
                XCTAssertTrue(c.content.contains("accessModifier: internal"), "\(name) \(c.path)")
                XCTAssertFalse(c.content.contains("accessModifier: package"), "\(name) \(c.path)")
            }
        }
    }

    func testApiHandlersExposePackageForwarderAndInternalOperations() throws {
        for name in ["iam-bundle.json", "iam-cross-agg-presenter-bundle.json"] {
            let outputs = try ApiHandlerRenderer.render(bundle: try fixture(name), contextName: "IAMContext", adapter: adapter)
            let handlers = outputs.filter { $0.path.hasSuffix("ApiHandler.swift") }
            XCTAssertFalse(handlers.isEmpty, name)
            for h in handlers {
                XCTAssertTrue(h.content.contains("package func registerApiHandlers("), "\(name) \(h.path)")
                XCTAssertTrue(h.content.contains("import OpenAPIRuntime"), "\(name) \(h.path)")
                // Operation methods take generated (internal) Operations.* types, so they must not be `package`.
                XCTAssertFalse(h.content.contains("package func grantPrivilege"), "\(name) \(h.path)")
                for line in h.content.split(separator: "\n") where line.contains("Operations.") && line.contains("func ") {
                    XCTAssertFalse(line.contains("package "), "\(name) \(h.path): \(line)")
                }
            }
        }
    }

    func testServerRegistersViaPackageForwarder() throws {
        for name in ["iam-bundle.json", "iam-cross-agg-presenter-bundle.json"] {
            let outputs = try ServerRenderer.render(bundle: try fixture(name), contextName: "IAMContext")
            let server = try XCTUnwrap(outputs.first { $0.path.hasSuffix("IAMContextServer.swift") }, name)
            XCTAssertTrue(server.content.contains(".registerApiHandlers(on: router"), name)
            XCTAssertFalse(server.content.contains(".registerHandlers("), "\(name): generated registerHandlers is internal")
        }
    }
}
