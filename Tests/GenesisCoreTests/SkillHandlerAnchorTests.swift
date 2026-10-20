import XCTest
@testable import GenesisCore

/// Skills locate / append ApiHandler operation methods by textual anchor. ApiHandler operation methods are
/// `internal` (their parameters are generated internal `Operations.*` types), so skill text must neither anchor on
/// nor instruct `package func <op>(_ input: Operations...`. These tests lock skill text to the codegen contract.
final class SkillHandlerAnchorTests: XCTestCase {
    private func skill(_ name: String) throws -> String {
        try SkillInstaller.bundledSkillFileContents(skill: name, file: "SKILL.md")
    }

    func testApiSkillAnchorMatchesGeneratedOperationMethod() throws {
        let text = try skill("api")
        XCTAssertTrue(text.contains("`func {ucCamel}(_`"))
        XCTAssertFalse(text.contains("package func {ucCamel}(_"))

        // The anchor must exist in real codegen output, and operation methods must not be `package`.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GenesisIntegrationTests/Fixtures/iam-cross-agg-presenter-bundle.json")
        let outputs = try ApiHandlerRenderer.render(
            bundle: try BundleParser.parseFull(at: url), contextName: "IAMContext",
            adapter: Adapter.defaultFor(contextName: "IAMContext"))
        let handlers = outputs.filter { $0.path.hasSuffix("ApiHandler.swift") }
        XCTAssertFalse(handlers.isEmpty)
        for h in handlers {
            XCTAssertNil(h.content.range(of: #"package func \w+\(_ input: Operations\."#, options: .regularExpression), h.path)
        }
        XCTAssertTrue(handlers.contains { $0.content.range(of: #"\n    func \w+\(_ input: Operations\."#, options: .regularExpression) != nil })
    }

    func testReadViewSkillDoesNotInstructPackageOperationMethod() throws {
        let text = try skill("read-view")
        XCTAssertNil(text.range(of: #"package func <opId>\(_ input: Operations"#, options: .regularExpression))
        XCTAssertTrue(text.contains("    func <opId>(_ input: Operations.<opId>.Input)"))
    }

    func testNoSkillInstructsPackageFuncWithOperationsParameter() throws {
        for name in try SkillInstaller.bundledSkillNames() {
            let text = try skill(name)
            XCTAssertNil(text.range(of: #"package func [^\n]*Operations\."#, options: .regularExpression), name)
        }
    }

    // MARK: test-gen template compile contracts (generated tests must build: `swift build --build-tests`)

    func testTestGenUsecaseLaneImportsContextShared() throws {
        let text = try skill("test-gen")
        let recipe = try XCTUnwrap(text.range(of: "## @Suite 骨架 recipe"))
        let rest = String(text[recipe.upperBound...])
        let block = try XCTUnwrap(rest.components(separatedBy: "```swift").dropFirst().first?.components(separatedBy: "```").first)
        XCTAssertTrue(block.contains("import <Ctx>Shared"), "ContextError lives in <Ctx>Shared")
        XCTAssertTrue(block.contains("import KurrentDB"))
    }

    func testTestGenApiLaneNeverUsesUnqualifiedOperations() throws {
        let text = try skill("test-gen")
        XCTAssertTrue(text.contains("<A>Aggregate.Operations.<ucCamel>"))
        // `import KurrentDB` also exposes `Operations`; bare `Operations.` is ambiguous. Only the prohibition line may mention it.
        for line in text.components(separatedBy: "\n") where !line.contains("裸寫") {
            XCTAssertNil(line.range(of: #"(?<![\w.>])Operations\."#, options: .regularExpression), line)
        }
    }

    func testReadViewTestSkeletonQualifiesOperationsAndImportsShared() throws {
        let text = try skill("read-view")
        XCTAssertTrue(text.contains("`import <Ctx>Shared`（斷言 `ContextError` 用）"))
        XCTAssertTrue(text.contains("`<A>Aggregate.Operations.<opId>`"))
    }
}
