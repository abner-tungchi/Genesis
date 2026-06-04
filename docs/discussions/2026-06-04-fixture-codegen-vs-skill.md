---
topic: "test fixtures: codegen vs /fixture-gen skill — the createX UsecaseCall helpers that Lane-B test Givens depend on"
status: consensus
created: "2026-06-04"
participants:
  - Claude (Opus 4.8)
  - adversarial workflow fixture-gen-discuss (3 lens: codegen-purist / ergonomics-judgment-skeptic / feasibility-integration + synthesis; swiftc 6.2.3)
facilitator: Claude
rounds_completed: 1
mode: default
premises:
  fixed:
    - "OC fixtures (Tests/.../SharedUtility/UsecaseCall/AuditQuoting.swift, ~50 helpers): @discardableResult func <verb>(...params..., repository: <A>Repository) async throws -> String? wrapping <UC>Service(repository:).execute(.init(...)). They EMBED baseline-judgment DEFAULTS (customerStatus = .established, organizationType = .limitedCompany — decide which invariants are reachable) + preset variants (addAccountingForTaxAccount hardcodes a curated Set<WorkItemType>+configs as a SEPARATE named func delegating to bare addAccounting)."
    - "codegen-vs-retrofit D1 (2026-06-02): deterministic fill → 收回 codegen (deterministic things belong in the renderer, not a skill); CI-lockability (Gemini G4) is the discriminator. D2 vetoed bundle-less drift (a skill reads code signatures; codegen reads the bundle SSOT)."
    - "Bundle carries per useCase: input [{name,type}], aggregate, useCase(verb), identityName, create-UC output.id → a bare wrapper is FULLY derivable. UseCaseRenderer.renderInput already computes the same canonical field set (aggId + business + operatorId)."
    - "Phase 1.x buildExecuteBody already codegens a STRICTLY HARDER thing (find→command→save→return + 4-arm catch ladder). A bare fixture is a one-liner around it."
    - "A fixture is a REAL execute() call → R-SUT red (throws GenesisTODO until /domain-fill); it is NOT a genesisTODO( thunk and lives in SharedUtility (pre-@Test preamble) → genesis verify FIX-2 does NOT flag it (verified vs VerifyChecker.swift)."
    - "FEASIBILITY-verified: a fixture referencing package <UC>Input/<A>Repository MUST live in the same-package TEST target (a Sources/ public func over package params fails to compile 'parameter uses a package type') → Tests/ is the only compilable home, matching OC's layout."
---

# test fixtures — codegen vs /fixture-gen skill

## 議題定義
test-gen v1 emits enabled-red usecase suites; the Lane-B JUDGMENT Given depends on FIXTURES (createX...) that test-gen only NAMES in a thunk message. We just established fixtures are on the CRITICAL PATH for TDD-ing invariants (an invariant-violation test stays red until its Given is authored, which needs fixtures). So: build the fixtures. The fork: is /fixture-gen a SKILL, or — given codegen-vs-retrofit D1 (deterministic→codegen) — should bare fixtures be CODEGEN?

## 裁決（FORK VERDICT）

**HYBRID, resolving the literal fork as「CODEGEN, not a skill」.** The bare single-UC fixture wrapper is emitted by a new **FixtureRenderer inside `genesis new`** (per-aggregate codegen), NOT by a `/fixture-gen` skill. For new projects there is **NO `/fixture-gen` skill** — its entire R2/D7 contract ("bare single-UC wrapper, EVERY param required, NO defaults, signature-derived, fail-loud on drift") IS the definition of a deterministic codegen target, and D1 is binding. A `/fixture-gen` skill survives only as a **migration-only niche** (codegen-vs-retrofit D4) for legacy projects codegen never bare-emitted for — **v1 does not build it**.

The residual codegen CANNOT emit — baseline-judgment defaults, curated presets, multi-step chains, cross-aggregate order — is **NOT a skill either**: it is **human-authored Swift in a sibling, never-overwritten preset file**. A future interactive elicitation belongs to **/fill-given's transcription secretary**, never a fixture-authoring LLM (an LLM authoring baseline judgment = the provenance corruption /domain-fill + /fill-given forbid).

## 決策 D1–D9

| # | 決定 | 理由 |
|---|------|------|
| **D1** | bare single-UC fixture = **CODEGEN via new `FixtureRenderer`** invoked by `genesis new` (per-aggregate). NOT a skill, NOT emitted by test-gen. /fixture-gen skill = migration-only niche, v1 不做。 | D1 binding: deterministic = pure fn = unit-testable = CI-lockable belongs in renderer. Bare wrapper is a pure fn of useCase.input/aggregate/verb/identityName + create output.id — same data UseCaseRenderer.renderInput iterates. Skill re-deriving it adds no judgment, is stochastic, re-opens bundle-less drift (D2). |
| **D2** | RESIDUAL stays **human-authored** (NOT codegen, NOT skill): (a) baseline-judgment defaults; (b) curated presets (hardcoded Set/config); (c) multi-step chains (order = judgment); (d) cross-agg arrangement order. Live in a human-owned sibling preset file, never overwritten. | These decide which invariants are reachable (AuditQuoting.swift:21 defaults, :264-277 curated Set). Codegen can't derive from bundle; a machine default re-opens the reachability-guess provenance hole. |
| **D3** | **Baseline-judgment (C2)**: bare wrapper = every param required, **ZERO defaults**. Ergonomic defaults/presets = **SEPARATE NAMED overloads** in the human preset file, mirroring OC's addAccountingForTaxAccount→addAccounting. Never a parameter default on the bare wrapper. | A default like `.established` is a reachability decision; on the ergonomic helper it corrupts provenance. Named single-location overload makes it visible/reviewable + beats pure-bare's hidden cost (humans re-add literals scattered+unversioned across N test files). |
| **D4** | **Location/naming/visibility/signature (C3)**: `Tests/<contextName>Tests/SharedUtility/UsecaseCall/<A>.swift` (per-agg, OC parity), **NOT Sources/**. `internal func` in the TEST target. Name = verb-derived (createX for create, lowerCamel useCase otherwise). `@discardableResult async throws -> String?` (output.id); params = <UC>Input business fields + operatorId + `repository: <A>Repository`, via SwiftTypeResolver so types match generated <UC>Input by construction. | Sources/ is type-system-FORBIDDEN (verified: <UC>Input/Repository are `package`; a public func over package params won't compile). Naming MUST agree with test-gen's thunk message (SKILL.md names <fixtureName>) — hard coordination requirement. |
| **D5** | **GenesisTODO/verify (C4)**: NO conflict. Fixture = real execute() → R-SUT red (throws GenesisTODO) until /domain-fill. NOT a genesisTODO( thunk; lives in SharedUtility = pre-@Test preamble → VerifyChecker FIX-2 does NOT flag it. | Verified vs shipped VerifyChecker: it segments on @Test and scans only parts.dropFirst(); preamble never scanned. catch-ladder rethrows GenesisTODO before catch-all → distinctive R-SUT red. |
| **D6** | **Cross-aggregate (C5)**: bare cross-agg fixture IS codegen'd — each aggregate's FixtureRenderer emits its own single-repository wrappers in its own <A>.swift. Consuming @Suite holds a SECOND `let <b>Repository`. JUDGMENT residual = which B-fixture + what order = human. | genesis new knows every aggregate's repository type → per-agg bare wrappers cover the cross-agg substrate free. Codegen structurally can't know cross-agg dependency/order = judgment. |
| **D7** | **Drift/ownership (C6)**: mirror test-gen two-file by manifest `role`, but **ASYMMETRIC**. Machine-owned <A>.swift (role `fixture`, regenerated WHOLESALE, sha256-tracked, version-guarded). Human-owned preset sibling (role `fixturePreset`/unmanaged, NEVER overwritten). Machine half has NO human counterpart to reconcile (no hole) → clean sha, regenerates fearlessly. | ManifestRenderer already carries `role` per file (existing mechanism). codegen-vs-retrofit D6: regen-conflict solved by manifest role. Caveat: until role-based regen/Phase-4 wired, separation is convention-enforced (same soft caveat as test-gen two-file). |
| **D8** | **Scope (C7)**: every MUTATING command UC gets a bare fixture (create + update + delete). Create = root fixture (returns new aggregate id). Read-side queries/presenters EXCLUDED (read, don't arrange state; read-model lane deferred). | All three are signature-derived execute calls; mirrors buildExecuteBody's create/update/delete dispatch. Read-side has no mutating execute to arrange. |
| **D9** | **Invariant-TDD unblock + /fill-given (C8)**: codegen'd bare fixtures unblock the MECHANICAL half of Lane-B's Given at genesis-new time (the thunk's named fixture compiles immediately). Human residual collapses to「pick trigger values + order existing fixture calls + (if needed) author a preset」. /fill-given transcribes the dictated Given USING codegen'd fixture names, never authoring the fixture. Loop: red → /domain-fill (clears R-SUT incl fixture's own execute) → /fill-given (composes fixtures+values, clears R-ARRANGE) → green. | Verified end-to-end (swift test went red AT the createAuditQuoting fixture call line). Codegen unblocks boilerplate, NOT judgment (which baseline/value/sequence) = /fill-given's job. |

## 改動面（change surface）
- **NEW** `Sources/GenesisCore/FixtureRenderer.swift` — pure renderer `static func render(...) -> [(path,content,role)]` mirroring UseCaseRenderer; emits `Tests/<Ctx>Tests/SharedUtility/UsecaseCall/<A>.swift` per aggregate (all mutating-command UC wrappers, role `fixture`); reuses SwiftTypeResolver + canonicalFields filter.
- **EDIT** `Sources/Genesis/Commands/NewCommand.swift` — per-aggregate FixtureRenderer loop, `try plan(...)` like every renderer; regenerated wholesale, manifest-sha-guarded.
- **NEW** golden-file unit test (Genesis's own suite) — byte-stable bundle→fixture mapping (create returns output.id / update / delete / multi-aggregate cross-agg). CI-lock is the whole point of codegen-over-skill.
- **EDIT** `test-gen/SKILL.md` — pin shared verb-derived naming so the thunk's <fixtureName> resolves to the codegen'd fixture; note fixtures EXIST at genesis-new time + test-gen CONSUMES (never emits) them; /fixture-gen = migration-only deferred.
- **NO CHANGE** to VerifyChecker.swift (fixtures invisible to FIX-2, confirmed).
- **OPTIONAL** (open Q): emit empty human-owned preset sibling stub on first genesis new.
- **DOCS**: phase-numbered spec (write-spec → audit-spec) + registry. This is a CODEGEN feature, not a skill registry entry.

## 開放問題（need user）→ user 拍板（2026-06-04）
1. **emit empty preset stub on `genesis new`?** → **NO（人需要時自己建）**。〔偏離 rec〕→ **載重 implication（D3 honesty 不能丟）**：因為不 emit stub，「defaults 放 sibling preset 檔、絕不放 bare wrapper」這條規則失去 signpost。改由 **machine-emitted `<A>.swift` 的 header 註解承載**此 guidance（檔本就機器生、wholesale 重生，header 自然）：header 須寫「GENESIS-GENERATED, regenerated wholesale — do NOT add defaults/presets here; create a human-owned sibling `<A>Fixtures.presets.swift` for ergonomic presets」。
2. **file naming** → **`<A>.swift`（bare, OC parity）+ `<A>Fixtures.presets.swift`（human, on-demand）**。bare 半無 human counterpart → 不用 `.generated/.authored` 儀式。
3. **delete-UC fixtures** → **YES：create + update + delete（全 OC parity）**。

## 下次討論指引
spec_ready = true；**3 開放問題已 user 拍板**（no-stub / `<A>.swift`+`<A>Fixtures.presets.swift` / create+update+delete）。下一步 write-spec（FixtureRenderer，phase 編號）→ audit-spec → impl。載重點：D4 location-MUST-be-Tests（package access）＋ D3 zero-defaults-on-bare（+ header signpost 取代被否決的 stub）＋ D7 asymmetric two-file role；naming MUST coordinate with test-gen thunk message（`<fixtureName>`）。
