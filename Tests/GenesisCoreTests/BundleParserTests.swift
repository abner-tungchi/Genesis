import XCTest
@testable import GenesisCore

final class BundleParserTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFixture(_ json: String, name: String = "bundle.json") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParseHappyPath() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc-123",
          "context": "FooContext"
        }
        """)
        let bundle = try BundleParser.parseMinimal(at: url)
        XCTAssertEqual(bundle.manifestVersion, 1)
        XCTAssertEqual(bundle.bundleId, "abc-123")
        XCTAssertEqual(bundle.context, "FooContext")
    }

    func testParseIgnoresExtraFields() throws {
        // The minimal parser must ignore aggregates/useCases/dtos (Phase 1.b territory).
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": "IAMContext",
          "aggregates": [{"aggregate": "Foo"}],
          "useCases": [],
          "dtos": []
        }
        """)
        let bundle = try BundleParser.parseMinimal(at: url)
        XCTAssertEqual(bundle.context, "IAMContext")
    }

    func testMissingContext() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc"
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseMinimal(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("context"), "reason should mention 'context'; got: \(reason)")
        }
    }

    func testMissingBundleId() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "context": "Foo"
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseMinimal(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("bundleId"))
        }
    }

    func testEmptyContextRejected() throws {
        let url = try writeFixture("""
        {
          "manifestVersion": 1,
          "bundleId": "abc",
          "context": ""
        }
        """)
        XCTAssertThrowsError(try BundleParser.parseMinimal(at: url)) { error in
            guard case .bundleInvalid = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
        }
    }

    func testMalformedJSON() throws {
        let url = try writeFixture("not valid json {")
        XCTAssertThrowsError(try BundleParser.parseMinimal(at: url)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("JSON malformed"))
        }
    }

    func testPathNotFound() throws {
        let nonexistent = tmpDir.appendingPathComponent("nope.json")
        XCTAssertThrowsError(try BundleParser.parseMinimal(at: nonexistent)) { error in
            guard case .bundleNotFound = error as? GenesisError else {
                return XCTFail("expected bundleNotFound, got \(error)")
            }
        }
    }

    func testPathIsDirectory() throws {
        XCTAssertThrowsError(try BundleParser.parseMinimal(at: tmpDir)) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("directory"))
        }
    }
}
