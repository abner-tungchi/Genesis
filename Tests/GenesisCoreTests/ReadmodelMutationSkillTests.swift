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
            XCTAssertTrue(row.contains("不影響這個 read model（no-op）") && row.contains("skip"), row)
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

    // MARK: - Round 2: independent read-back findings

    /// A collection payload can be this event's delta or a full snapshot; nothing in the name or type tells which,
    /// and a wrong guess compiles. So no collection-payload event is ever mechanical — removeAll / append struct stay
    /// mechanical only when the payload shape rules out the snapshot reading (one element), and assignList is out.
    func testCollectionPayloadAmbiguityIsNeverAutoDecided() throws {
        let rows = lines(try skill())
        XCTAssertTrue(rows.contains { $0.contains("集合型 payload 的差量／快照歧義永遠不自動判定") })
        let removeAll = rows.filter { $0.contains("**removeAll**") }
        XCTAssertFalse(removeAll.isEmpty)
        for row in removeAll { XCTAssertTrue(row.contains("單一元素的 id locator"), row) }
        let append = rows.filter { $0.contains("**append struct**") }
        XCTAssertFalse(append.isEmpty)
        for row in append { XCTAssertTrue(row.contains("單一元素的完整欄位"), row) }
        let assignList = try XCTUnwrap(rows.first { $0.contains("**assignList**") })
        XCTAssertTrue(assignList.contains("不屬 mechanical"), assignList)
    }

    func testNoOpMarkerBlockHasNoPlaceholders() throws {
        let rows = lines(try skill())
        let intro = try XCTUnwrap(rows.firstIndex { $0.hasPrefix("no-op 標記（") })
        let open = try XCTUnwrap(rows[intro...].firstIndex { $0 == "```swift" })
        let close = try XCTUnwrap(rows[(open + 1)...].firstIndex { $0 == "```" })
        let block = rows[(open + 1)..<close].joined(separator: "\n")
        XCTAssertTrue(block.contains("// readmodel-mutation: no-op —"), block)
        XCTAssertFalse(block.contains("_ = readModel"), block)
        XCTAssertFalse(block.contains("_ = event"), block)
    }

    func testUnfilledAggregateHoleAlwaysGoesToAsk() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("aggregate 的 `when(event:)` 還是洞（含 `GenesisTODO`，`/domain-fill` skip 過）→ 不可沿用，該欄位一律歸 ask"))
    }

    func testSkipLeavesWholeStubIncludingAggregateIdLine() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("人選 skip → 該方法整段 stub 原封不動（aggregate-id 那行也不寫"))
        XCTAssertTrue(text.contains("skip / manual 的方法不動"))
    }

    func testWholeTableConfirmationOffersWriteAllSkipAllAndPerRowEdits() throws {
        let rows = lines(try skill())
        let confirm = try XCTUnwrap(rows.first { $0.hasPrefix("5c.") })
        for option in ["「照表寫入」", "「全部 skip（不寫）」", "`#列號：改法`"] {
            XCTAssertTrue(confirm.contains(option), "\(option) missing: \(confirm)")
        }
    }

    func testPartialFillIsCheckedBeforeAnyWrite() throws {
        let text = try skill()
        XCTAssertTrue(text.contains("半填在**寫入前**檢查：一次列出全部半填方法，什麼都不寫"))
    }

    func testExit1CoversEveryMissingPrerequisite() throws {
        let rows = lines(try skill())
        let exit1 = try XCTUnwrap(rows.first { $0.hasPrefix("| exit 1 |") })
        for item in ["arg 空", "presenter", "ReadModel", "event.yaml"] {
            XCTAssertTrue(exit1.contains(item), "\(item) missing: \(exit1)")
        }
        let eventYamlInput = try XCTUnwrap(rows.first { $0.contains("**event.yaml**") })
        XCTAssertTrue(eventYamlInput.contains("→ exit 1"), "Phase 3 must say a missing event.yaml exits 1: \(eventYamlInput)")
    }

    // MARK: - Round 2: user decisions

    /// For a collection payload the first question asks what the payload IS (this event's delta / full snapshot /
    /// no-op / skip); only "delta" leads to a second question (add / remove). Other shapes get a single question.
    func testCollectionAskIsTwoStageAndBatchedWithinAskUserQuestionLimits() throws {
        let text = try skill()
        let rows = lines(text)
        let collectionRow = try XCTUnwrap(rows.first { $0.hasPrefix("| payload 集合 → 同名 readModel 集合") })
        XCTAssertTrue(collectionRow.contains("兩段式"), collectionRow)
        for option in ["這次的差量", "完整快照（整欄覆寫）", "不影響這個 read model（no-op）", "skip", "加入（聯集／追加）", "移除（差集）"] {
            XCTAssertTrue(collectionRow.contains(option), "\(option) missing: \(collectionRow)")
        }
        let scalarRow = try XCTUnwrap(rows.first { $0.hasPrefix("| payload scalar") })
        XCTAssertTrue(scalarRow.contains("單題"), scalarRow)
        let wholeEventRow = try XCTUnwrap(rows.first { $0.hasPrefix("| 整個事件") })
        XCTAssertTrue(wholeEventRow.contains("單題"), wholeEventRow)
        XCTAssertTrue(text.contains("每次 AskUserQuestion 最多 4 題、每題最多 4 個 options"))
        XCTAssertTrue(text.contains("第二題要等第一題的回答"), "a second-stage question never shares a call with its first stage")
    }

    /// `/readmodel-mutation getPermissions` used to exit 1 because stripGet only recognizes a leading `Get`.
    /// The read model type now comes from the presenter's own `typealias ReadModelType`, and a lowercase
    /// first letter is retried before giving a case-sensitivity hint.
    func testPresenterNameCaseToleranceReadsTypealias() throws {
        let text = try skill()
        let start = try XCTUnwrap(text.range(of: "## Phase 1 — "))
        let end = try XCTUnwrap(text.range(of: "## Phase 2 — "))
        let phase1 = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(phase1.contains("`typealias ReadModelType = <X>`"))
        XCTAssertTrue(phase1.contains("找不到 typealias 才退回 `<stripGet(presenterName)>ReadModel`"))
        XCTAssertTrue(phase1.contains("首字改大寫再 Glob 一次"))
        XCTAssertTrue(phase1.contains("`struct <Name>Presenter`"), "the canonical name comes from the file, not the argument's case")
        XCTAssertTrue(phase1.contains("PascalCase"), "the not-found message must hint at case sensitivity")
    }

    /// /domain-fill used to call /readmodel-mutation a deterministic / type-closure fill that runs before it. It now
    /// runs after /domain-fill and only reuses the write-side semantics confirmed there.
    func testDomainFillDescribesReadmodelMutationReuse() throws {
        let text = try SkillInstaller.bundledSkillFileContents(skill: "domain-fill", file: "SKILL.md")
        for stale in [
            "/usecase /api /readmodel-mutation (deterministic fills)",
            "deterministic fill skills（/usecase /api /readmodel-mutation）",
            "/readmodel-mutation 跑完機械層",
            "/readmodel-mutation（read，type-closure deterministic）",
            "read type-closure（/readmodel-mutation）",
        ] {
            XCTAssertFalse(text.contains(stale), stale)
        }
        XCTAssertTrue(text.contains("只沿用本 skill 已確認的寫入端語意"))
    }

    /// `genesis verify` treats a whole-value `readModel = …` assignment as a mutation; the skill's 已填 row must
    /// agree, else one body reads "filled" to verify but half-filled (exit 4) to the skill.
    func testFilledRowAcceptsWholeReadModelAssignmentAndPlaceholderPlusMutationIsHalfFilled() throws {
        let text = try skill()
        let filled = try XCTUnwrap(lines(text).first { $0.hasPrefix("| 已填 |") })
        XCTAssertTrue(filled.contains("`readModel = …`"), "已填 row must accept whole-value assignment: \(filled)")
        let half = try XCTUnwrap(lines(text).first { $0.hasPrefix("| 半填 |") })
        XCTAssertTrue(half.contains("placeholder 與 mutation 並存"), half)
    }
}
