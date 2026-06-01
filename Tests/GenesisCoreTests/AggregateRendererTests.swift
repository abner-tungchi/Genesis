import XCTest
@testable import GenesisCore

final class AggregateRendererTests: XCTestCase {
    private func loadIAMBundle() throws -> FullBundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("GenesisIntegrationTests/Fixtures/iam-bundle.json")
        return try BundleParser.parseFull(at: url)
    }

    private var defaultAdapter: Adapter { .defaultFor(contextName: "IAMContext") }

    private func render(_ bundle: FullBundle, spec: AggregateSpec? = nil) throws -> [(path: String, content: String, role: String)] {
        let s = spec ?? bundle.aggregates[0]
        return try AggregateRenderer.render(
            spec: s,
            bundle: bundle,
            adapter: defaultAdapter,
            contextName: "IAMContext"
        )
    }

    // MARK: - Path layout (Phase 1.e migration)

    func testRenderProducesExpectedFiles() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let paths = outputs.map { $0.path }
        XCTAssertTrue(paths.contains("Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift"))
        XCTAssertTrue(paths.contains("Sources/UserAccessProfileAggregate/UserAccessProfileError.swift"))
        XCTAssertTrue(paths.contains("Sources/UserAccessProfileAggregate/Usecase/Port/Out/UserAccessProfileRepository.swift"))
        XCTAssertTrue(paths.contains("Sources/UserAccessProfileAggregate/event.yaml"))
        XCTAssertTrue(paths.contains("Sources/UserAccessProfileAggregate/event-generator-config.yaml"))
        XCTAssertTrue(paths.contains("Sources/UserAccessProfileAggregate/projection-model.yaml"))
        XCTAssertTrue(paths.contains("Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+Delete.swift"))
        XCTAssertTrue(paths.contains("Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+GrantPrivilege.swift"))
        XCTAssertTrue(paths.contains("Sources/UserAccessProfileAggregate/Usecase/Port/In/GrantPrivilege/GrantPrivilegeInput.swift"))
        XCTAssertTrue(paths.contains("Sources/UserAccessProfileAggregate/Usecase/Service/GrantPrivilegeService.swift"))

        // Phase 1.b legacy paths must NOT exist anymore
        XCTAssertFalse(paths.contains("Sources/UserAccessProfileAggregate/UserAccessProfile.swift"))
        XCTAssertFalse(paths.contains("Sources/UserAccessProfileAggregate/Adapter/UserAccessProfileRepository.swift"))
    }

    // MARK: - Aggregate.swift canonical shape

    func testAggregateConformsToGeneratedProtocol() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let aggFile = outputs.first { $0.path.hasSuffix("UserAccessProfile.swift") }!.content
        XCTAssertTrue(aggFile.contains("package class UserAccessProfile: UserAccessProfileAggregateProtocol"))
    }

    func testAggregateHasLetIdString() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let aggFile = outputs.first { $0.path.hasSuffix("UserAccessProfile.swift") }!.content
        XCTAssertTrue(aggFile.contains("package let id: String"))
        XCTAssertFalse(aggFile.contains("typealias ID = "), "Phase 1.e: ID == String enforced by Entity protocol; no typealias needed")
        XCTAssertFalse(aggFile.contains("typealias CreatedEventType"), "Phase 1.e: gradyzhuo kit has no CreatedEventType associatedtype")
    }

    func testAggregateHasCategoryPrefix() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let aggFile = outputs.first { $0.path.hasSuffix("UserAccessProfile.swift") }!.content
        XCTAssertTrue(aggFile.contains("\"IAMC\\(Self.self)\""), "category should use IAMContext uppercase letters → IAMC prefix")
    }

    func testAggregateHasNoWhenHappened() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let aggFile = outputs.first { $0.path.hasSuffix("UserAccessProfile.swift") }!.content
        XCTAssertFalse(aggFile.contains("when(happened"), "Phase 1.e: plugin-generated default provides when(happened:); hand-written switch removed")
    }

    func testAggregateIsNonFinalClass() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let aggFile = outputs.first { $0.path.hasSuffix("UserAccessProfile.swift") }!.content
        XCTAssertFalse(aggFile.contains("package final class"), "Phase 1.e: non-final class (OC convention; allows test doubles + required convenience init)")
    }

    func testAggregateConvenienceInitDelegates() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let aggFile = outputs.first { $0.path.hasSuffix("UserAccessProfile.swift") }!.content
        XCTAssertTrue(aggFile.contains("required convenience init?(first createdEvent: UserAccessProfileCreated"))
        XCTAssertTrue(aggFile.contains("try self.init("))
        XCTAssertTrue(aggFile.contains("id: createdEvent.useraccessprofileId"), "convenience init delegates id via alias")
    }

    // MARK: - High-priority defenses (added per audit pass 2)

    func testCreatedEventStateAssignmentsSkipNonStatePayload() throws {
        // IAM bundle would historically have had `initialPermissions` in eventPayload but only `permissions`
        // in state — that orphan field would silently render `self.initialPermissions = initialPermissions`
        // and fail to compile with a confusing error. Phase 1.e requires fail-fast bundle validation.
        // We simulate the orphan-field scenario inline.
        let bundle = try loadIAMBundle()
        let spec = bundle.aggregates[0]
        let alteredUCs = bundle.useCases.map { uc -> UseCaseSpec in
            if uc.aggregate == spec.name && uc.emittedEvent == "userAccessProfileCreated" {
                let altered = uc.eventPayload.map { f -> FieldSpec in
                    f.name == "permissions" ? FieldSpec(name: "initialPermissions", rawType: f.rawType) : f
                }
                return UseCaseSpec(
                    useCaseSpecId: uc.useCaseSpecId,
                    aggregateSpecId: uc.aggregateSpecId,
                    useCase: uc.useCase,
                    aggregate: uc.aggregate,
                    input: uc.input,
                    emittedEvent: uc.emittedEvent,
                    eventPayload: altered,
                    preconditions: uc.preconditions
                )
            }
            return uc
        }
        let altered = FullBundle(
            manifestVersion: bundle.manifestVersion,
            bundleId: bundle.bundleId,
            context: bundle.context,
            aggregates: bundle.aggregates,
            useCases: alteredUCs,
            dtos: bundle.dtos,
            readModels: bundle.readModels
        )
        XCTAssertThrowsError(try AggregateRenderer.render(
            spec: spec, bundle: altered, adapter: defaultAdapter, contextName: "IAMContext"
        )) { error in
            guard case let GenesisError.bundleInvalid(reason) = error else {
                XCTFail("expected bundleInvalid, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("initialPermissions"), "reason should name orphan field: \(reason)")
            XCTAssertTrue(reason.contains("no matching state"), "reason should explain the mismatch: \(reason)")
        }
    }

    func testCreatedEventInvocationIncludesAliasFirst() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let aggFile = outputs.first { $0.path.hasSuffix("UserAccessProfile.swift") }!.content
        // OC pattern: event init args are `id: UUID()`, then alias `useraccessprofileId: id`, then payload fields.
        // The alias must be the FIRST arg after `id:` (matches `AuditQuotingCreated(quotingId: id, ...)`).
        XCTAssertTrue(aggFile.contains("let event = UserAccessProfileCreated("))
        XCTAssertTrue(aggFile.contains("id: UUID()"))
        XCTAssertTrue(aggFile.contains("useraccessprofileId: id"))
        // Sanity: alias line appears between `id: UUID()` and the first payload field
        if let idRange = aggFile.range(of: "id: UUID()"),
           let aliasRange = aggFile.range(of: "useraccessprofileId: id"),
           let payloadRange = aggFile.range(of: "userId: userId") {
            XCTAssertLessThan(idRange.lowerBound, aliasRange.lowerBound)
            XCTAssertLessThan(aliasRange.lowerBound, payloadRange.lowerBound)
        } else {
            XCTFail("missing expected segments: \(aggFile)")
        }
    }

    func testCreatedEventStateAssignmentsRendered() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let aggFile = outputs.first { $0.path.hasSuffix("UserAccessProfile.swift") }!.content
        // IAM bundle's createUserAccessProfile eventPayload: userId, department, jobTitle, permissions, roles, status.
        // All should appear as `self.X = X` in init body before apply(event:).
        XCTAssertTrue(aggFile.contains("self.userId = userId"))
        XCTAssertTrue(aggFile.contains("self.permissions = permissions"))
        XCTAssertTrue(aggFile.contains("self.roles = roles"))
        XCTAssertTrue(aggFile.contains("self.status = status"))
    }

    // MARK: - Error enum

    func testErrorEnumContainsAllInvariantCodes() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let errFile = outputs.first { $0.path.hasSuffix("UserAccessProfileError.swift") }!.content
        XCTAssertTrue(errFile.contains("case userIdNotExist"))
        XCTAssertTrue(errFile.contains("case permissionNotMatch"))
        XCTAssertTrue(errFile.contains("case employeeNotActive"))
        XCTAssertTrue(errFile.contains(": Error, Equatable"))
        XCTAssertFalse(errFile.contains(": Error, Sendable"))
    }

    // MARK: - event.yaml

    func testEventYamlQuotesContainerTypes() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let yaml = outputs.first { $0.path.hasSuffix("event.yaml") }!.content

        XCTAssertTrue(yaml.contains("PrivilegeGranted:"))
        XCTAssertTrue(yaml.contains("kind: createdEvent") || yaml.contains("kind: domainEvent"))
        XCTAssertTrue(yaml.contains("alias: useraccessprofileId"))

        // Phase 1.o D5: map shape (was array `- name: X\n  type: "Y"` pre-1.o).
        // All values quoted per D5=B; container types stay safe from YAML flow-sequence parsing.
        XCTAssertTrue(yaml.contains("permissions: \"[String]\""), "Phase 1.o map shape: container types still quoted")
        XCTAssertTrue(yaml.contains("userId: \"String\""), "Phase 1.o map shape: scalar types also quoted per D5=B")
        XCTAssertFalse(yaml.contains("- name: userId"), "Phase 1.o: array shape `- name:` must be gone")
        XCTAssertFalse(yaml.contains("- name: permissions"), "Phase 1.o: array shape `- name:` must be gone")

        XCTAssertTrue(yaml.contains("UserAccessProfileDeleted:"), "Genesis auto-adds the Deleted event")
        XCTAssertTrue(yaml.contains("kind: deletedEvent"))
    }

    func testDeletedEventYamlOmitsAliasAndProperties() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let yaml = outputs.first { $0.path.hasSuffix("event.yaml") }!.content
        // The deletedEvent block must contain ONLY `<Name>:\n  kind: deletedEvent` (matches OC ground truth).
        guard let range = yaml.range(of: "UserAccessProfileDeleted:") else {
            XCTFail("missing deletedEvent block: \(yaml)")
            return
        }
        // Inspect the 3 lines starting at the deletedEvent name
        let tail = yaml[range.lowerBound...]
        let endIndex = tail.firstIndex(where: { $0 == "\n" }).flatMap {
            tail.index($0, offsetBy: 30, limitedBy: tail.endIndex)
        } ?? tail.endIndex
        let block = String(tail[..<endIndex])
        XCTAssertTrue(block.contains("kind: deletedEvent"))
        XCTAssertFalse(block.contains("aggregateRootId"), "deletedEvent block must NOT have aggregateRootId: \(block)")
        XCTAssertFalse(block.contains("properties:"), "deletedEvent block must NOT have properties list: \(block)")
    }

    // MARK: - DeleteCommandExtension

    func testDeleteCommandExtensionRendered() throws {
        let bundle = try loadIAMBundle()
        let outputs = try render(bundle)
        let delFile = outputs.first { $0.path.hasSuffix("+Delete.swift") }!
        XCTAssertEqual(delFile.path, "Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+Delete.swift")
        XCTAssertTrue(delFile.content.contains("extension UserAccessProfile {"))
        XCTAssertTrue(delFile.content.contains("package func when(event: UserAccessProfileDeleted) throws"))
        XCTAssertTrue(delFile.content.contains("self.metadata.delete()"))
    }

    // MARK: - typedStruct deprecation

    func testAdapterIdStrategyTypedStructFallsBackToString() throws {
        // Phase 1.e: typedStruct is deprecated (kit enforces ID == String).
        let bundle = try loadIAMBundle()
        let spec = bundle.aggregates[0]
        let typedAdapter = Adapter(
            adapterVersion: 1, schemaVersion: 1, contextName: "IAMContext", bundleId: nil,
            typeMapping: [:], customTypes: [],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .typedStruct, wrapper: "{Aggregate}ID")
        )
        let outputs = try AggregateRenderer.render(
            spec: spec, bundle: bundle, adapter: typedAdapter, contextName: "IAMContext"
        )
        let aggFile = outputs.first { $0.path.hasSuffix("UserAccessProfile.swift") }!.content
        XCTAssertFalse(aggFile.contains("UserAccessProfileID"), "typedStruct ID wrapper must not appear in aggregate body (Phase 1.e deprecation)")
        XCTAssertTrue(aggFile.contains("package let id: String"))
    }

    // MARK: - Phase 1.t.1: create-input convenience init (D3a)

    func testCreateInputConvenienceInitWhenDerivedFields() throws {
        // iam-bundle create UC: input [userId, department, jobTitle] ⊊ payload [+permissions, roles, status]
        // → derived fields exist → emit an input-only convenience init (honest fatalError TODO).
        let bundle = try loadIAMBundle()
        let aggFile = try render(bundle).first { $0.role == "aggregate" }!.content
        XCTAssertTrue(
            aggFile.contains("package convenience init(id: String, userId: String, department: String, jobTitle: String) throws"),
            "create UC with non-input payload fields should get an input-only convenience init; got:\n\(aggFile)"
        )
        XCTAssertTrue(aggFile.contains("GENESIS-TODO: derive non-input"), "convenience init body must be an honest TODO")
        // designated full-payload init unchanged (replay path)
        XCTAssertTrue(aggFile.contains("permissions: Set<String>, roles: Set<String>, status: EmployeeStatus) throws"),
                      "designated full-payload init must remain")
        // input-only convenience init must NOT carry operatorId
        XCTAssertFalse(aggFile.contains("jobTitle: String, operatorId"), "operatorId must be filtered out of the convenience init")
    }

    func testNoConvenienceInitWhenInputCoversPayload() throws {
        // minimal-bundle create UC: input [bar] == payload [bar] → no derived fields → the designated init's
        // signature already == input business fields, so emitting a convenience init would COLLIDE → must NOT emit.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("GenesisIntegrationTests/Fixtures/minimal-bundle.json")
        let bundle = try BundleParser.parseFull(at: url)
        let outputs = try AggregateRenderer.render(
            spec: bundle.aggregates[0], bundle: bundle,
            adapter: .defaultFor(contextName: "MinimalContext"), contextName: "MinimalContext"
        )
        let aggFile = outputs.first { $0.role == "aggregate" }!.content
        XCTAssertFalse(
            aggFile.contains("package convenience init(id: String,"),
            "create UC whose input covers the whole payload must NOT emit an input-only convenience init; got:\n\(aggFile)"
        )
    }
}
