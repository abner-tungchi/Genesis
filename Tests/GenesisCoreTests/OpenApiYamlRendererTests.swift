import XCTest
@testable import GenesisCore

/// Phase 1.t.2 / PA-F5: collection fields must map to OpenAPI `type: array` (+ items), not the `string`
/// fallback. The bug surfaced via /api dogfood — Cosmogony emits bracket notation (Array[X] / Set[X])
/// which the old yamlType (angle-only) missed, so `permissions: [String]` rendered as `type: string`,
/// breaking /api fill (payload.permissions: String vs AS Input [String]) and the generated API contract.
final class OpenApiYamlRendererTests: XCTestCase {

    func testCollectionElementTypeRecognizesBracketAndAngleNotation() {
        XCTAssertEqual(OpenApiYamlRenderer.collectionElementType(of: "Array[String]"), "String")
        XCTAssertEqual(OpenApiYamlRenderer.collectionElementType(of: "Set[String]"), "String")
        XCTAssertEqual(OpenApiYamlRenderer.collectionElementType(of: "Array<String>"), "String")
        XCTAssertEqual(OpenApiYamlRenderer.collectionElementType(of: "Set<String>"), "String")
        XCTAssertEqual(OpenApiYamlRenderer.collectionElementType(of: "[String]"), "String")
        XCTAssertEqual(OpenApiYamlRenderer.collectionElementType(of: "Array[Int]?"), "Int")
        XCTAssertNil(OpenApiYamlRenderer.collectionElementType(of: "String"))
        XCTAssertNil(OpenApiYamlRenderer.collectionElementType(of: "Int"))
    }

    func testYamlTypeMapsBracketCollectionToArray() {
        // regression for PA-F5: Array[String] used to fall through to "string"
        XCTAssertEqual(OpenApiYamlRenderer.yamlType(for: "Array[String]"), "array")
        XCTAssertEqual(OpenApiYamlRenderer.yamlType(for: "Set[String]"), "array")
        XCTAssertEqual(OpenApiYamlRenderer.yamlType(for: "[String]"), "array")
        XCTAssertEqual(OpenApiYamlRenderer.yamlType(for: "String"), "string")
        XCTAssertEqual(OpenApiYamlRenderer.yamlType(for: "Int"), "integer")
        XCTAssertEqual(OpenApiYamlRenderer.yamlType(for: "Bool"), "boolean")
    }

    func testRequestBodyCollectionFieldRendersArrayWithItems() throws {
        // End-to-end through the renderer: grantPrivilege.permissions (Array[String]) → type: array + items.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json")
        let bundle = try BundleParser.parseFull(at: url)
        let outputs = try OpenApiYamlRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: .defaultFor(contextName: "IAMContext")
        )
        let yaml = outputs.first { $0.path.hasSuffix("openapi.yaml") }!.content
        // GrantPrivilegeRequest.permissions must be an array of string, not a bare string.
        XCTAssertTrue(yaml.contains("type: array"), "collection request field should render type: array")
        XCTAssertTrue(yaml.contains("items:"), "array request field must carry an items schema")
        XCTAssertFalse(
            yaml.contains("permissions:\n          type: string"),
            "permissions (Array[String]) must NOT render as type: string (PA-F5 regression)"
        )
    }
}
