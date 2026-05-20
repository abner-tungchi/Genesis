import XCTest
@testable import GenesisCore

final class SwiftTypeResolverTests: XCTestCase {
    func testPrimitivesIdentity() throws {
        for p in ["String", "Int", "Bool", "Decimal", "Date", "UUID", "Float", "Double"] {
            XCTAssertEqual(try SwiftTypeResolver.resolve(rawType: p, knownCustomTypes: []), p)
        }
    }

    func testArrayContainerRewritesToBrackets() throws {
        XCTAssertEqual(try SwiftTypeResolver.resolve(rawType: "Array[String]", knownCustomTypes: []), "[String]")
        XCTAssertEqual(try SwiftTypeResolver.resolve(rawType: "Array[Int]", knownCustomTypes: []), "[Int]")
    }

    func testSetContainerIdentityButValidatesInner() throws {
        XCTAssertEqual(try SwiftTypeResolver.resolve(rawType: "Set<String>", knownCustomTypes: []), "Set<String>")
        // Inner is unknown → throws
        XCTAssertThrowsError(try SwiftTypeResolver.resolve(rawType: "Set<UnknownT>", knownCustomTypes: []))
    }

    func testKnownCustomType() throws {
        let known: Set<String> = ["EmployeeStatus"]
        XCTAssertEqual(try SwiftTypeResolver.resolve(rawType: "EmployeeStatus", knownCustomTypes: known), "EmployeeStatus")
    }

    func testUnknownTypeRejected() {
        XCTAssertThrowsError(try SwiftTypeResolver.resolve(rawType: "XYZ", knownCustomTypes: [])) { error in
            guard case .bundleInvalid(let reason) = error as? GenesisError else {
                return XCTFail("expected bundleInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("XYZ"))
        }
    }

    func testNestedArrayOfArray() throws {
        XCTAssertEqual(
            try SwiftTypeResolver.resolve(rawType: "Array[Array[String]]", knownCustomTypes: []),
            "[[String]]"
        )
    }
}
