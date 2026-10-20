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
}
