import XCTest
@testable import GenesisCore

final class ManifestRendererTests: XCTestCase {
    private func makeBundle() -> FullBundle {
        FullBundle(
            manifestVersion: 1,
            bundleId: "bundle-test",
            context: "Foo",
            aggregates: [],
            useCases: [],
            dtos: []
        )
    }

    func testRendersDeterministicOutputWithFrozenDate() throws {
        let bundle = makeBundle()
        let files: [(String, String, String)] = [
            ("a.swift", "hello", "aggregate"),
            ("b.swift", "world", "service"),
        ]
        let m1 = try ManifestRenderer.render(
            bundle: bundle, contextName: "Foo", genesisVersion: "0.0.1",
            exportedAt: "2026-01-01T00:00:00Z",
            files: files
        )
        let m2 = try ManifestRenderer.render(
            bundle: bundle, contextName: "Foo", genesisVersion: "0.0.1",
            exportedAt: "2026-01-01T00:00:00Z",
            files: files
        )
        XCTAssertEqual(m1.content, m2.content, "manifest must be deterministic given the same inputs")
    }

    func testManifestContainsExpectedKeysAndSha() throws {
        let bundle = makeBundle()
        let m = try ManifestRenderer.render(
            bundle: bundle, contextName: "Foo", genesisVersion: "0.0.1",
            exportedAt: "2026-01-01T00:00:00Z",
            files: [("foo.swift", "hello", "aggregate")]
        )
        XCTAssertEqual(m.path, ".ai/contexts/Foo/.scaffold-manifest.json")
        XCTAssertTrue(m.content.contains("\"manifestVersion\""))
        XCTAssertTrue(m.content.contains("\"bundleId\""))
        XCTAssertTrue(m.content.contains("\"templateVersion\""))
        XCTAssertTrue(m.content.contains("\"exportedAt\""))
        XCTAssertTrue(m.content.contains("\"generatedFiles\""))
        // sha256 of "hello" is well-known
        XCTAssertTrue(
            m.content.contains("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"),
            m.content
        )
    }

    func testRoleIsCarriedThroughExplicitly() throws {
        let bundle = makeBundle()
        let m = try ManifestRenderer.render(
            bundle: bundle, contextName: "Foo", genesisVersion: "0.0.1",
            exportedAt: "2026-01-01T00:00:00Z",
            files: [
                ("Sources/FooShared/X.swift", "x", "valueObject"),
                ("Sources/FooShared/Y.swift", "y", "idWrapper"),
            ]
        )
        XCTAssertTrue(m.content.contains("\"role\" : \"valueObject\""))
        XCTAssertTrue(m.content.contains("\"role\" : \"idWrapper\""))
    }
}
