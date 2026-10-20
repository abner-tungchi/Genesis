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

    // MARK: - presenter GET response schema (read API path, #28)

    private func renderPresenterYaml(kind: PresenterOutputKind, elementType: String) throws -> String {
        let agg = AggregateSpec(
            aggregateSpecId: "agg-1", name: "Thing", identityName: "thingId",
            state: [], invariants: [], eventNames: ["Created"]
        )
        let presenter = PresenterSpec(
            presenterSpecId: "p-GetThings", name: "GetThings", readModelRef: "GetThings",
            aggregateRef: "Thing",
            input: PresenterInput(fields: [PresenterInputField(name: "thingId", type: "String", fromPath: "thingId")]),
            output: PresenterOutput(kind: kind, elementType: elementType, elementSource: "things"),
            endpoint: PresenterEndpoint(path: "/thing/{thingId}/things", method: "GET"),
            comment: nil
        )
        let bundle = FullBundle(
            manifestVersion: 1, bundleId: "t", context: "ThingContext",
            aggregates: [agg], useCases: [], dtos: [], readModels: [], presenters: [presenter]
        )
        let outputs = try OpenApiYamlRenderer.render(
            bundle: bundle, contextName: "ThingContext", adapter: .defaultFor(contextName: "ThingContext")
        )
        return outputs.first { $0.path.hasSuffix("openapi.yaml") }!.content
    }

    func testPresenterArrayOfPrimitiveRendersInlineItemsNotRef() throws {
        let yaml = try renderPresenterYaml(kind: .array, elementType: "String")
        XCTAssertTrue(yaml.contains("                type: array\n                items:\n                  type: string"), yaml)
        XCTAssertFalse(yaml.contains("schemas/String"), "String is not a component schema")
    }

    func testPresenterSinglePrimitiveRendersInlineType() throws {
        let yaml = try renderPresenterYaml(kind: .single, elementType: "Int")
        XCTAssertTrue(yaml.contains("              schema:\n                type: integer"), yaml)
        XCTAssertFalse(yaml.contains("schemas/Int"), yaml)
    }

    func testPresenterArrayOfCustomTypeStillUsesRef() throws {
        let yaml = try renderPresenterYaml(kind: .array, elementType: "ThingDto")
        XCTAssertTrue(yaml.contains("items:\n                  $ref: '#/components/schemas/ThingDto'"), yaml)
    }

    func testPresenterSingleCustomTypeStillUsesRef() throws {
        let yaml = try renderPresenterYaml(kind: .single, elementType: "ThingDto")
        XCTAssertTrue(yaml.contains("schema:\n                $ref: '#/components/schemas/ThingDto'"), yaml)
    }
}
