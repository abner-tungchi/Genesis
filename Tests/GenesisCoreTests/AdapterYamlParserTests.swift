import XCTest
@testable import GenesisCore

final class AdapterYamlParserTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdapterParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFixture(_ yaml: String) throws -> URL {
        let url = tmpDir.appendingPathComponent("adapter.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testHappyPathMinimal() throws {
        let url = try writeFixture("""
        adapterVersion: 1
        schemaVersion: 1
        contextName: IAMContext
        aggregateSplit:
          strategy: byBoundedContext
        idStrategy:
          kind: direct
        """)
        let adapter = try AdapterYamlParser.parse(at: url, contextName: "IAMContext", bundleId: "x")
        XCTAssertEqual(adapter.contextName, "IAMContext")
        XCTAssertEqual(adapter.idStrategy.kind, .direct)
        XCTAssertTrue(adapter.typeMapping.isEmpty)
        XCTAssertTrue(adapter.customTypes.isEmpty)
    }

    func testHappyPathFull() throws {
        let url = try writeFixture("""
        adapterVersion: 1
        schemaVersion: 1
        contextName: IAMContext
        bundleId: bundle-xyz
        typeMapping:
          "Array[String]": "[String]"
        customTypes:
          - name: EmployeeStatus
            kind: enum
            cases: [active, suspended]
          - name: EmailAddress
            kind: valueObject
            underlying: String
          - name: UserAccessProfileID
            kind: identifier
            underlying: UUID
        createdEventOverrides:
          UserAccessProfile: createUserAccessProfile
        aggregateSplit:
          strategy: byBoundedContext
        idStrategy:
          kind: typedStruct
          wrapper: "{Aggregate}ID"
        """)
        let adapter = try AdapterYamlParser.parse(at: url, contextName: "IAMContext", bundleId: "bundle-xyz")
        XCTAssertEqual(adapter.typeMapping["Array[String]"], "[String]")
        XCTAssertEqual(adapter.customTypes.count, 3)
        XCTAssertEqual(adapter.idStrategy.kind, .typedStruct)
        XCTAssertEqual(adapter.idStrategy.wrapper, "{Aggregate}ID")
        XCTAssertEqual(adapter.createdEventOverrides["UserAccessProfile"], "createUserAccessProfile")
    }

    func testRejectUnsupportedAdapterVersion() throws {
        let url = try writeFixture("""
        adapterVersion: 2
        schemaVersion: 1
        contextName: X
        aggregateSplit:
          strategy: byBoundedContext
        idStrategy:
          kind: direct
        """)
        XCTAssertThrowsError(try AdapterYamlParser.parse(at: url, contextName: "X", bundleId: "y")) { error in
            guard case .adapterInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected adapterInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("adapterVersion"))
        }
    }

    func testRejectContextMismatch() throws {
        let url = try writeFixture("""
        adapterVersion: 1
        schemaVersion: 1
        contextName: Foo
        aggregateSplit:
          strategy: byBoundedContext
        idStrategy:
          kind: direct
        """)
        XCTAssertThrowsError(try AdapterYamlParser.parse(at: url, contextName: "Bar", bundleId: "x")) { error in
            guard case .adapterIncompatible(let reason) = error as? GenesisError else {
                return XCTFail("expected adapterIncompatible, got \(error)")
            }
            XCTAssertTrue(reason.contains("contextName"))
        }
    }

    func testRejectBundleIdMismatch() throws {
        let url = try writeFixture("""
        adapterVersion: 1
        schemaVersion: 1
        contextName: X
        bundleId: A
        aggregateSplit:
          strategy: byBoundedContext
        idStrategy:
          kind: direct
        """)
        XCTAssertThrowsError(try AdapterYamlParser.parse(at: url, contextName: "X", bundleId: "B")) { error in
            guard case .adapterIncompatible(let reason) = error as? GenesisError else {
                return XCTFail("expected adapterIncompatible, got \(error)")
            }
            XCTAssertTrue(reason.contains("bundleId"))
        }
    }

    func testRejectInvalidAggregateSplitStrategy() throws {
        let url = try writeFixture("""
        adapterVersion: 1
        schemaVersion: 1
        contextName: X
        aggregateSplit:
          strategy: byFeature
        idStrategy:
          kind: direct
        """)
        XCTAssertThrowsError(try AdapterYamlParser.parse(at: url, contextName: "X", bundleId: "y")) { error in
            guard case .adapterInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected adapterInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("aggregateSplit"))
        }
    }

    func testRejectTypedStructWithoutWrapper() throws {
        let url = try writeFixture("""
        adapterVersion: 1
        schemaVersion: 1
        contextName: X
        aggregateSplit:
          strategy: byBoundedContext
        idStrategy:
          kind: typedStruct
        """)
        XCTAssertThrowsError(try AdapterYamlParser.parse(at: url, contextName: "X", bundleId: "y")) { error in
            guard case .adapterInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected adapterInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("wrapper"))
        }
    }

    func testRejectEnumCustomTypeWithoutCases() throws {
        let url = try writeFixture("""
        adapterVersion: 1
        schemaVersion: 1
        contextName: X
        customTypes:
          - name: Foo
            kind: enum
        aggregateSplit:
          strategy: byBoundedContext
        idStrategy:
          kind: direct
        """)
        XCTAssertThrowsError(try AdapterYamlParser.parse(at: url, contextName: "X", bundleId: "y")) { error in
            guard case .adapterInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected adapterInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("cases"))
        }
    }

    func testFileNotFound() {
        let bogus = tmpDir.appendingPathComponent("nope.yaml")
        XCTAssertThrowsError(try AdapterYamlParser.parse(at: bogus, contextName: "X", bundleId: "y")) { error in
            guard case .adapterNotFound = error as? GenesisError else {
                return XCTFail("expected adapterNotFound, got \(error)")
            }
        }
    }
}
