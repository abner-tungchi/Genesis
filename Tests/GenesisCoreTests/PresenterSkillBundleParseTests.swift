import XCTest
@testable import GenesisCore

/// #36: a Cosmogony canvas export has `readModels[].queryName / parameters / returnType` (no `name` / `key` /
/// `storedFields` — Genesis derives those while parsing), and `presenters[].readModelRef` must be the
/// Genesis-normalized PascalCase name. So `/presenter` must read read models through `genesis bundle-parse`
/// (same approach as `/bundle-plan`) and write back to the ORIGINAL bundle, keeping the canvas export format.
final class PresenterSkillBundleParseTests: XCTestCase {
    private func presenterSkill() throws -> String {
        try SkillInstaller.bundledSkillFileContents(skill: "presenter", file: "SKILL.md")
    }

    func testPresenterSkillReadsReadModelsViaBundleParse() throws {
        let text = try presenterSkill()
        XCTAssertTrue(text.contains("genesis bundle-parse <bundle.json>"), "must obtain canonical readModels via bundle-parse")
        XCTAssertTrue(text.contains("不自己解析 bundle JSON schema"), "must not hand-parse the canvas schema")
        // Bash is needed to run bundle-parse.
        let frontmatterTools = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("allowed-tools:") })
        XCTAssertTrue(frontmatterTools.contains("Bash"), frontmatterTools)
    }

    func testPresenterSkillExplainsCanvasFieldsAndCanonicalName() throws {
        let text = try presenterSkill()
        XCTAssertTrue(text.contains("queryName"), "must mention the canvas-export field")
        XCTAssertTrue(text.contains("returnType"))
        XCTAssertTrue(text.contains("canonical `readModels[].name`"), "readModelRef / default presenter name come from the canonical name")
        XCTAssertTrue(text.contains("PascalCase"))
    }

    func testPresenterSkillWritesBackToOriginalBundleNotCanonicalDump() throws {
        let text = try presenterSkill()
        XCTAssertTrue(text.contains("不要把 `genesis bundle-parse` 的輸出寫回"), "canonical JSON must never replace the canvas export")
        XCTAssertTrue(text.contains("原始 bundle"), "write target is the original bundle file")
        XCTAssertTrue(text.contains("genesis bundle-parse") && text.contains("驗證"), "post-write bundle-parse validation step")
    }
}
