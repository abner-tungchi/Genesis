import XCTest
@testable import GenesisCore

/// M1 — TestLayout deriver: golden deep-path derivation + the drift-guard that keeps the LLM test-gen
/// SKILL.md prose in lock-step with the Swift single-source path templates.
final class TestLayoutTests: XCTestCase {

    // MARK: - golden: concrete deep paths

    func testUsecasePathsAreDeepAndLayerSuffixed() {
        XCTAssertEqual(
            TestLayout.testPath(contextName: "IAMContext", aggregateName: "UserAccessProfile",
                                ucPascal: "PromoteUser", layer: .usecase, file: .generated),
            "Tests/IAMContextTests/UserAccessProfileAggregate/Usecases/PromoteUser/PromoteUserUsecaseTests.generated.swift"
        )
        XCTAssertEqual(
            TestLayout.testPath(contextName: "IAMContext", aggregateName: "UserAccessProfile",
                                ucPascal: "PromoteUser", layer: .usecase, file: .authored),
            "Tests/IAMContextTests/UserAccessProfileAggregate/Usecases/PromoteUser/PromoteUserUsecaseTests.authored.swift"
        )
    }

    func testApiPathsAreDeepAndLayerSuffixed() {
        XCTAssertEqual(
            TestLayout.testPath(contextName: "IAMContext", aggregateName: "UserAccessProfile",
                                ucPascal: "GrantPrivilege", layer: .api, file: .generated),
            "Tests/IAMContextTests/UserAccessProfileAggregate/Api/GrantPrivilege/GrantPrivilegeApiTests.generated.swift"
        )
        XCTAssertEqual(
            TestLayout.testPath(contextName: "IAMContext", aggregateName: "UserAccessProfile",
                                ucPascal: "GrantPrivilege", layer: .api, file: .authored),
            "Tests/IAMContextTests/UserAccessProfileAggregate/Api/GrantPrivilege/GrantPrivilegeApiTests.authored.swift"
        )
    }

    func testFixtureAndSupportPaths() {
        XCTAssertEqual(
            TestLayout.fixturePath(contextName: "IAMContext", aggregateName: "UserAccessProfile"),
            "Tests/IAMContextTests/SharedUtility/UsecaseCall/UserAccessProfile.swift"
        )
        XCTAssertEqual(
            TestLayout.supportPath(contextName: "IAMContext"),
            "Tests/IAMContextTests/GenesisTestSupport.swift"
        )
    }

    /// FixtureRenderer's path was swapped to `TestLayout.fixturePath`; this pins that they agree (so the
    /// FixtureRendererTests golden, which hard-codes the same string, cannot silently diverge from the deriver).
    func testFixtureTemplateMatchesFixtureRendererPath() {
        XCTAssertEqual(
            TestLayout.fixturePath(contextName: "DemoContext", aggregateName: "Foo"),
            "Tests/DemoContextTests/SharedUtility/UsecaseCall/Foo.swift"
        )
    }

    // MARK: - drift-guard: SKILL.md prose mirrors the Swift templates byte-for-byte

    func testTestGenSkillProseMirrorsAllTemplates() throws {
        let skill = try SkillInstaller.bundledSkillFileContents(skill: "test-gen", file: "SKILL.md")

        // M2: usecase + api + support templates are all mirrored in the SKILL prose.
        let guarded = [
            TestLayout.usecaseGeneratedTemplate,
            TestLayout.usecaseAuthoredTemplate,
            TestLayout.apiGeneratedTemplate,
            TestLayout.apiAuthoredTemplate,
            TestLayout.supportTemplate,
        ]
        for template in guarded {
            XCTAssertFalse(template.isEmpty, "TestLayout template must be non-empty")
        }

        // Guard the AUTHORITATIVE copy, not whole-file membership. A whole-file `skill.contains(template)` is
        // green-by-vacuum: the usecase/support paths ALSO appear in prose bullets + the glob line, so corrupting
        // ONLY the canonical fenced ```…``` path block (the one SKILL.md marks 禁改字元) would still pass on the
        // prose copies. Instead: split on the ``` fence and require EXACTLY ONE fenced segment to contain ALL
        // five templates verbatim — that segment IS the canonical block, and corrupting any single template in
        // it drops the count to 0 → fails. (Found by the M1+M2 impl-review: the old whole-file form let a
        // one-char mutation of the canonical block pass.)
        let fencedSegments = skill.components(separatedBy: "```").enumerated()
            .filter { $0.offset % 2 == 1 }   // odd segments sit INSIDE a fenced block
            .map { $0.element }
        let canonicalBlocks = fencedSegments.filter { seg in guarded.allSatisfy { seg.contains($0) } }
        XCTAssertEqual(
            canonicalBlocks.count, 1,
            "exactly ONE fenced block in test-gen SKILL.md must contain ALL five TestLayout path templates "
                + "verbatim (the canonical path block); corrupting any single template in it must trip this"
        )

        // half-migration guard: the OLD flat path tokens must be gone, else a stale flat path lingers.
        XCTAssertFalse(
            skill.contains("Tests/<contextName>Tests/<ucPascal>Tests.generated.swift"),
            "stale FLAT generated test path still present in test-gen SKILL.md — DEEP migration incomplete"
        )
        XCTAssertFalse(
            skill.contains("Tests/<contextName>Tests/<ucPascal>Tests.authored.swift"),
            "stale FLAT authored test path still present in test-gen SKILL.md — DEEP migration incomplete"
        )
    }
}
