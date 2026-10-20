import XCTest
@testable import GenesisCore

/// /readmodel-mutation batch review + reuse (handover run, run-log #37–#40): the first method without a pattern
/// used to abort the whole run (`GetPermissions` filled 0 of 7), the aggregate-id alias was invisible, an
/// intentional no-op body read as half-filled, and union/difference semantics already confirmed in
/// `/domain-fill` were asked again. AI writes the code, the human answers semantics; delta (add/remove) vs
/// snapshot is still never guessed. These tests lock the rules the LLM must follow in SKILL.md.
final class ReadmodelMutationSkillTests: XCTestCase {
    private func skill() throws -> String {
        try SkillInstaller.bundledSkillFileContents(skill: "readmodel-mutation", file: "SKILL.md")
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    func testFrontmatterDeclaresAskUserQuestionAndWriteAndStaysUserInvoked() throws {
        let text = try skill()
        let tools = try XCTUnwrap(lines(text).first { $0.hasPrefix("allowed-tools:") })
        for tool in ["Read", "Edit", "Write", "Glob", "Grep", "AskUserQuestion"] {
            XCTAssertTrue(tools.contains(tool), "\(tool) missing: \(tools)")
        }
        XCTAssertTrue(text.contains("\ndisable-model-invocation: true\n"))
        let description = try XCTUnwrap(lines(text).first { $0.hasPrefix("description:") })
        XCTAssertTrue(description.contains("review table"), description)
        XCTAssertTrue(description.contains("reuse-from-aggregate"), description)
    }

    func testReuseReadsFilledAggregateWhenEventAsConfirmedProposal() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("reuse-from-aggregate"))
        XCTAssertTrue(text.contains("Entity/Commands/<A>+<UC>.swift"))
        XCTAssertTrue(text.contains("func when(event: <E>)"))
        XCTAssertTrue(text.contains("init?(first createdEvent: <E>"), "createdEvent state is set by the Entity/<A>.swift rehydration init")
        XCTAssertTrue(text.contains("GenesisTODO"), "an aggregate hole left by /domain-fill skip must not be reused")
        XCTAssertTrue(text.contains("人確認才寫"), "a reuse proposal is written only after the human confirms it")
        XCTAssertTrue(text.contains("docs/domain-fill-provenance.md"), "show the human's earlier dictation as the basis")
    }

    func testReuseConvertsSetSemanticsToArrayEquivalents() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("不重複追加、保留順序"))
        XCTAssertTrue(text.contains("for element in event.<g> where !<f>.contains(element) { <f>.append(element) }"))
        XCTAssertTrue(text.contains("<f>.removeAll { event.<g>.contains($0) }"))
        XCTAssertTrue(text.contains("event.<g>.sorted()"), "Set has no order; sorted() keeps the read model reproducible")
    }

    func testAggregateIdAliasIsDeterministicAndMergedIntoBody() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("aggregateRootId"))
        XCTAssertTrue(text.contains("aggregateRootId.alias"))
        XCTAssertTrue(text.contains("readModel.<f> = event.<alias>"))
        XCTAssertTrue(text.contains("**合併**"), "the aggregate-id line joins whatever else the method body gets")
        XCTAssertTrue(text.contains("key 欄位"), "the read model key field is never asked about")
    }

    func testBatchClassifiesEveryMethodAndNeverAbortsOnOneMethod() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("manual > ask > reuse-from-aggregate > mechanical > aggregate-id"))
        XCTAssertTrue(text.contains("| # | when(event) | 類別 | 提議的程式碼 / 問題 | 依據 |"))
        XCTAssertTrue(text.contains("一次寫入"))
        XCTAssertTrue(text.contains("不因單一方法無法處理就中止"))
        XCTAssertFalse(text.contains("整次 abort"), "v1 aborted the whole run at the first method without a pattern")
        XCTAssertTrue(text.contains("insert-at-position") && text.contains("reorder"), "complex cases stay manual")
    }

    func testDeltaVerbsAreNeverAutoFilledIncludingAssignList() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("`Granted | Revoked | Added | Removed | Deleted | Assigned`"))
        XCTAssertTrue(text.contains("不猜增減語意"))
        let assignList = try XCTUnwrap(lines(text).first { $0.contains("**assignList**") })
        XCTAssertTrue(assignList.contains("delta"), "assignList must exclude delta verbs too (run-log #39): \(assignList)")
    }

    func testAskOptionsFollowPayloadShapeAndAlwaysOfferNoOpAndSkip() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("AskUserQuestion"))
        let optionRows = lines(text).filter { $0.hasPrefix("| payload ") || $0.hasPrefix("| 整個事件") }
        XCTAssertGreaterThanOrEqual(optionRows.count, 3)
        for row in optionRows {
            XCTAssertTrue(row.contains("不影響（no-op）") && row.contains("skip"), row)
        }
        for word in ["聯集", "差集", "覆寫", "口述"] {
            XCTAssertTrue(text.contains(word), word)
        }
    }

    func testNoOpMarkerCountsAsFilled() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("// readmodel-mutation: no-op — <理由>"))
        let filledRow = try XCTUnwrap(lines(text).first { $0.hasPrefix("| 已填 |") })
        XCTAssertTrue(filledRow.contains("readmodel-mutation: no-op"), filledRow)
        let partialRow = try XCTUnwrap(lines(text).first { $0.hasPrefix("| 半填 |") })
        XCTAssertTrue(partialRow.contains("無 no-op 標記"), partialRow)
    }

    func testProvenanceIsAppendedForNonMechanicalDecisions() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("docs/readmodel-mutation-provenance.md"))
        XCTAssertTrue(text.contains("| presenter:when(event):欄位 | 類別 | 依據（沿用的 aggregate 片段 / 人回答原文） | 填入 Swift |"))
    }

    func testExitCodesAreRedefined() throws {
        let rows = lines(try skill())
        let exit0 = try XCTUnwrap(rows.first { $0.hasPrefix("| exit 0 |") })
        XCTAssertTrue(exit0.contains("no-op") && exit0.contains("skip"), exit0)
        let exit4 = try XCTUnwrap(rows.first { $0.hasPrefix("| exit 4 |") })
        XCTAssertTrue(exit4.contains("半填") && exit4.contains("同名 presenter"), exit4)
        let exit3 = try XCTUnwrap(rows.first { $0.hasPrefix("| exit 3 |") })
        XCTAssertTrue(exit3.contains("manual"), exit3)
        for line in rows where line.contains("exit 3") {
            XCTAssertTrue(line.contains("全部"), "exit 3 may only mean 'every unfilled method is manual': \(line)")
        }
    }

    func testSkillStaysWithinLineBudgetWithBatchPhases() throws {
        let text = try skill()
        XCTAssertLessThanOrEqual(lines(text).count, 260)
        XCTAssertTrue(text.contains("## Phase 5 — 審閱表"))
        XCTAssertTrue(text.contains("## Phase 6 — 一次寫入"))
    }
}
