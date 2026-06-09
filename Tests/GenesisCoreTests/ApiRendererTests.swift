import XCTest
@testable import GenesisCore

final class ApiRendererTests: XCTestCase {

    private func writeUC(useCase: String = "createUserAccessProfile") -> UseCaseSpec {
        UseCaseSpec(
            useCaseSpecId: "uc-1", aggregateSpecId: "agg-1",
            useCase: useCase, aggregate: "UserAccessProfile",
            input: [
                FieldSpec(name: "useraccessprofileId", rawType: "String"),
                FieldSpec(name: "userId", rawType: "String"),
                FieldSpec(name: "operatorId", rawType: "String"),
            ],
            emittedEvent: "userAccessProfileCreated",
            eventPayload: [], preconditions: []
        )
    }

    private func bundleWith(useCases: [UseCaseSpec] = [], dtos: [DtoSpec] = []) -> FullBundle {
        FullBundle(
            manifestVersion: 1, bundleId: "t", context: "IAMContext",
            aggregates: [
                AggregateSpec(
                    aggregateSpecId: "agg-1", name: "UserAccessProfile",
                    identityName: "useraccessprofileId", state: [], invariants: [],
                    eventNames: ["userAccessProfileCreated"]
                )
            ],
            useCases: useCases, dtos: dtos, readModels: []
        )
    }

    private func defaultAdapter() -> Adapter { .defaultFor(contextName: "IAMContext") }

    // MARK: - Happy path AS

    func testVariantAApplicationServiceShape() throws {
        let uc = writeUC()
        let bundle = bundleWith(useCases: [uc])
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: adapter,
            ownership: ownership
        )
        XCTAssertEqual(outputs.count, 1)
        let f = outputs[0]
        XCTAssertEqual(f.path, "Sources/UserAccessProfileAggregate/Adapter/CreateUserAccessProfile/CreateUserAccessProfileApplicationService.swift")
        XCTAssertEqual(f.role, "applicationService")
        let c = f.content
        XCTAssertTrue(c.contains("package struct CreateUserAccessProfileApplicationServiceInput"))
        XCTAssertTrue(c.contains("package let useraccessprofileId: String"))
        XCTAssertTrue(c.contains("package let userId: String"))
        XCTAssertTrue(c.contains("package let operatorId: String"))
        XCTAssertTrue(c.contains(": ApplicationService"))
        XCTAssertTrue(c.contains("TODO(/api skill)"))
        // Phase: /api fatalError→GenesisTODO migration — the execute stub now THROWS the marker (enabled-red,
        // no SIGABRT, caught by genesis verify) instead of fatalError.
        XCTAssertTrue(c.contains("throw GenesisTODO.notImplemented("))
        XCTAssertFalse(c.contains("fatalError"))
        // operatorId must come LAST per OC (audit M1)
        if let opRange = c.range(of: "        self.operatorId = operatorId"),
           let userRange = c.range(of: "        self.userId = userId") {
            XCTAssertLessThan(userRange.lowerBound, opRange.lowerBound, "operatorId must be assigned LAST in init body")
        }
    }

    // MARK: - Read UC skip

    func testReadUCSkipped() throws {
        let bundle = bundleWith(useCases: [
            writeUC(useCase: "createUserAccessProfile"),
            writeUC(useCase: "getUserAccessProfile"),
            writeUC(useCase: "listUserAccessProfiles"),
            writeUC(useCase: "findUserAccessProfile"),
        ])
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: adapter,
            ownership: ownership
        )
        XCTAssertEqual(outputs.count, 1, "only 1 write UC should emit AS")
        XCTAssertTrue(outputs[0].path.contains("CreateUserAccessProfile"))
    }

    // MARK: - Scaffold-once

    func testScaffoldOnceSkipsExisting() throws {
        let bundle = bundleWith(useCases: [writeUC()])
        let existing: Set<String> = [
            "Sources/UserAccessProfileAggregate/Adapter/CreateUserAccessProfile/CreateUserAccessProfileApplicationService.swift"
        ]
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: adapter,
            existingPaths: existing,
            ownership: ownership
        )
        XCTAssertTrue(outputs.isEmpty, "existing path must be skipped")
    }

    // MARK: - Enum DTO mapper

    func testEnumDtoMapperBidirectional() throws {
        let dto = DtoSpec(
            dtoSpecId: "d-1", name: "EmployeeStatusDto", description: "",
            fields: [],
            dtoKind: "enum",
            cases: ["activate", "resigned"],
            domainTypeName: "EmployeeStatus",
            isContextShared: false,
            aggregateRef: "UserAccessProfile"
        )
        let bundle = bundleWith(dtos: [dto])
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: adapter,
            ownership: ownership
        )
        XCTAssertEqual(outputs.count, 1)
        let f = outputs[0]
        XCTAssertEqual(f.path, "Sources/UserAccessProfileAggregate/Adapter/Dto/EmployeeStatusDto+Domain.swift")
        XCTAssertEqual(f.role, "dtoEnumMapper")
        let c = f.content
        XCTAssertTrue(c.contains("extension EmployeeStatusDto"))
        XCTAssertTrue(c.contains("extension EmployeeStatus"))
        XCTAssertTrue(c.contains("init(from domain: EmployeeStatus)"))
        XCTAssertTrue(c.contains("init(from dto: EmployeeStatusDto)"))
        XCTAssertTrue(c.contains("case .activate: self = .activate"))
        XCTAssertTrue(c.contains("case .resigned: self = .resigned"))
    }

    // MARK: - Struct DTO scaffold

    func testStructDtoScaffoldHasTodo() throws {
        let dto = DtoSpec(
            dtoSpecId: "d-1", name: "ProfileDto", description: "",
            fields: [
                FieldSpec(name: "userId", rawType: "String"),
                FieldSpec(name: "department", rawType: "String"),
            ],
            dtoKind: "struct",
            cases: [],
            domainTypeName: "Profile",
            isContextShared: false,
            aggregateRef: "UserAccessProfile"
        )
        let bundle = bundleWith(dtos: [dto])
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: adapter,
            ownership: ownership
        )
        XCTAssertEqual(outputs.count, 1)
        let c = outputs[0].content
        XCTAssertTrue(c.contains("self.userId = domain.userId"))
        XCTAssertTrue(c.contains("self.department = domain.department"))
        XCTAssertTrue(c.contains("TODO(/api skill)"))
        // Phase: /api fatalError→GenesisTODO migration — the DTO toDomain stub THROWS the marker
        // (init(from:) is throws), enabled-red + verify-caught, instead of fatalError.
        XCTAssertTrue(c.contains("throw GenesisTODO.notImplemented("))
        XCTAssertFalse(c.contains("fatalError"))
    }

    // MARK: - Union DTO defer

    func testUnionDtoSkippedWithoutEmit() throws {
        let dto = DtoSpec(
            dtoSpecId: "d-1", name: "WorkItemDto", description: "",
            fields: [],
            dtoKind: "union",
            cases: [],
            domainTypeName: nil,
            isContextShared: false,
            aggregateRef: "UserAccessProfile"
        )
        let bundle = bundleWith(dtos: [dto])
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: adapter,
            ownership: ownership
        )
        XCTAssertTrue(outputs.isEmpty, "union DTO defers Phase 1.i.2; no emit")
    }

    // MARK: - isContextShared filtering

    func testContextSharedDtoNotEmittedByApiRenderer() throws {
        // isContextShared=true → SharedTargetRenderer handles, not ApiRenderer
        let dto = DtoSpec(
            dtoSpecId: "d-1", name: "AccountingTypeDto", description: "",
            fields: [],
            dtoKind: "enum",
            cases: ["auditCertification"],
            domainTypeName: "AccountingType",
            isContextShared: true
        )
        let bundle = bundleWith(dtos: [dto])
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: adapter,
            ownership: ownership
        )
        XCTAssertTrue(outputs.isEmpty, "context-shared DTO not emitted by ApiRenderer (per audit M4)")
    }

    // MARK: - Phase 1.o.1 F6 — identity-mapper skip

    func testNoDtoSuffixSkipsIdentityMapper() throws {
        // F6 root cause: when dto.name has no `Dto` suffix and no explicit domainTypeName,
        // domainTypeName(for:) falls back to dto.name. Mapper template emits both
        // `extension <X> { init(from domain: <X>) }` and `extension <X> { init(from dto: <X>) }`
        // on the SAME Swift type → "invalid redeclaration of 'init(from:)'". Skip emit entirely;
        // convention says use a `Dto` suffix (or set domainTypeName) when a wire/domain split is wanted.
        let dto = DtoSpec(
            dtoSpecId: "d-1", name: "EmployeeStatus", description: "",
            fields: [],
            dtoKind: "enum",
            cases: ["active", "resigned"],
            domainTypeName: nil,
            isContextShared: false,
            aggregateRef: "UserAccessProfile"
        )
        let bundle = bundleWith(dtos: [dto])
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: adapter,
            ownership: ownership
        )
        XCTAssertTrue(outputs.isEmpty, "F6: DTO without Dto suffix → no identity mapper emitted")
    }

    func testExplicitDomainTypeNameEqualToDtoNameSkipsMapper() throws {
        // Same skip condition triggered via explicit domainTypeName collision.
        let dto = DtoSpec(
            dtoSpecId: "d-1", name: "Status", description: "",
            fields: [],
            dtoKind: "enum",
            cases: ["a", "b"],
            domainTypeName: "Status",
            isContextShared: false,
            aggregateRef: "UserAccessProfile"
        )
        let bundle = bundleWith(dtos: [dto])
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle, contextName: "IAMContext", adapter: adapter, ownership: ownership
        )
        XCTAssertTrue(outputs.isEmpty, "F6: explicit domainTypeName equal to dto.name also skips")
    }

    // MARK: - Legacy DTO fallback (audit M3)

    func testLegacyDtoEnumByDescriptionFallback() throws {
        // No dtoKind → fallback to description-based inference (legacy DtoRenderer behavior)
        // Phase 1.n: explicit shared since legacy default was removed.
        let dto = DtoSpec(
            dtoSpecId: "d-1", name: "Legacy", description: "This is a Enum",
            fields: [FieldSpec(name: "a", rawType: ""), FieldSpec(name: "b", rawType: "")],
            dtoKind: nil,
            cases: [],
            domainTypeName: nil,
            isContextShared: true
        )
        let bundle = bundleWith(dtos: [dto])
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle,
            contextName: "IAMContext",
            adapter: adapter,
            ownership: ownership
        )
        XCTAssertTrue(outputs.isEmpty, "legacy DTO with isContextShared=true skipped")
    }

    // MARK: - Helpers

    func testIsReadUseCase() {
        XCTAssertTrue(ApiRenderer.isReadUseCase("getUser"))
        XCTAssertTrue(ApiRenderer.isReadUseCase("listUsers"))
        XCTAssertTrue(ApiRenderer.isReadUseCase("findUser"))
        XCTAssertFalse(ApiRenderer.isReadUseCase("createUser"))
        XCTAssertFalse(ApiRenderer.isReadUseCase("editUser"))
    }

    func testDomainTypeNameStripDtoSuffix() {
        let dto = DtoSpec(dtoSpecId: "d", name: "FooDto", description: "", fields: [])
        XCTAssertEqual(ApiRenderer.domainTypeName(for: dto), "Foo")

        let dto2 = DtoSpec(dtoSpecId: "d", name: "Bar", description: "", fields: [], domainTypeName: "BarDomain")
        XCTAssertEqual(ApiRenderer.domainTypeName(for: dto2), "BarDomain")
    }

    // MARK: - Phase 1.p D13 + Phase 1.p.1 D4 — DTO swap + structured TODO marker

    func testDtoTypeSwapAndStructuredTodoEmitted() throws {
        // Bundle: UC input contains `status: EmployeeStatus`, dto registers
        // EmployeeStatusDto with domainTypeName=EmployeeStatus + scope=aggregate + usage=request.
        // ApiRenderer should:
        //   (1) Swap AS Input field `status` type from `EmployeeStatus` to `EmployeeStatusDto`
        //   (2) Emit structured TODO marker `genesis-todo(phase=1.p.1, kind=dto-init-from-input, field=status, dto=EmployeeStatusDto)`
        let uc = UseCaseSpec(
            useCaseSpecId: "uc-1", aggregateSpecId: "agg-1",
            useCase: "updateProfile", aggregate: "UserAccessProfile",
            input: [
                FieldSpec(name: "useraccessprofileId", rawType: "String"),
                FieldSpec(name: "status", rawType: "EmployeeStatus"),
                FieldSpec(name: "operatorId", rawType: "String"),
            ],
            emittedEvent: "profileUpdated",
            eventPayload: [], preconditions: []
        )
        let dto = DtoSpec(
            dtoSpecId: "d-1", name: "EmployeeStatusDto", description: "",
            fields: [],
            dtoKind: "enum",
            cases: ["active", "resigned"],
            domainTypeName: "EmployeeStatus",
            scope: "aggregate",
            usage: "request",
            useCaseRef: nil,
            readModelRef: nil
        )
        let bundle = FullBundle(
            manifestVersion: 1, bundleId: "t", context: "IAMContext",
            aggregates: [
                AggregateSpec(
                    aggregateSpecId: "agg-1", name: "UserAccessProfile",
                    identityName: "useraccessprofileId", state: [], invariants: [],
                    eventNames: ["profileUpdated"]
                )
            ],
            useCases: [uc], dtos: [dto], readModels: []
        )
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle, contextName: "IAMContext", adapter: adapter, ownership: ownership
        )
        // Find the AS file
        guard let asFile = outputs.first(where: { $0.role == "applicationService" }) else {
            return XCTFail("expected applicationService output")
        }
        let c = asFile.content

        // (1) AS Input field swap: type should be EmployeeStatusDto, NOT EmployeeStatus
        XCTAssertTrue(c.contains("package let status: EmployeeStatusDto"),
                      "Phase 1.p D13: AS Input field type swapped to wire DTO; got: \(c)")
        XCTAssertFalse(c.contains("package let status: EmployeeStatus\n"),
                       "Phase 1.p D13: domain type must NOT appear in AS Input (it's swapped to Dto)")

        // (2) Structured TODO marker (with-space format per D4 R3 lock)
        XCTAssertTrue(c.contains("// genesis-todo(phase=1.p.1, kind=dto-init-from-input, field=status, dto=EmployeeStatusDto)"),
                      "Phase 1.p.1 D4: structured TODO marker must be emitted with exact format; got: \(c)")
    }

    func testNoTodoMarkerWhenNoDtoSwap() throws {
        // When UC input has only primitive fields (no domain-type swap), no marker emitted.
        let uc = writeUC()  // all-String input fields
        let bundle = bundleWith(useCases: [uc])
        let adapter = defaultAdapter()
        let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
        let outputs = try ApiRenderer.render(
            bundle: bundle, contextName: "IAMContext", adapter: adapter, ownership: ownership
        )
        let asFile = outputs.first { $0.role == "applicationService" }
        XCTAssertNotNil(asFile)
        XCTAssertFalse(asFile!.content.contains("genesis-todo"),
                       "no marker when no DTO swap")
    }
}
