import XCTest
@testable import GenesisCore

final class CaseTransformerTests: XCTestCase {
    func testUpperCamel() {
        XCTAssertEqual(CaseTransformer.upperCamel("grantPrivilege"), "GrantPrivilege")
        XCTAssertEqual(CaseTransformer.upperCamel("Foo"), "Foo")
        XCTAssertEqual(CaseTransformer.upperCamel(""), "")
    }

    func testLowerCamel() {
        XCTAssertEqual(CaseTransformer.lowerCamel("GrantPrivilege"), "grantPrivilege")
        XCTAssertEqual(CaseTransformer.lowerCamel("foo"), "foo")
        XCTAssertEqual(CaseTransformer.lowerCamel(""), "")
    }

    func testSingleCharacter() {
        XCTAssertEqual(CaseTransformer.upperCamel("a"), "A")
        XCTAssertEqual(CaseTransformer.lowerCamel("A"), "a")
    }
}
