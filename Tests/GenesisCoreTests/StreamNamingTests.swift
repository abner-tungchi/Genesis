import XCTest
@testable import GenesisCore

/// M2b — the single-source stream-prefix derivation that aligns the aggregate write category, the JS projection
/// fromStreams, and the Presenter categoryRule (previously two different derivations that only coincided for OC).
final class StreamNamingTests: XCTestCase {

    func testCategoryPrefixIsUppercaseLetters() throws {
        XCTAssertEqual(try StreamNaming.categoryPrefix(contextName: "OpportunityContext"), "OC")
        XCTAssertEqual(try StreamNaming.categoryPrefix(contextName: "IAMContext"), "IAMC")
        XCTAssertEqual(try StreamNaming.categoryPrefix(contextName: "AuditQuotingContext"), "AQC")
        XCTAssertEqual(try StreamNaming.categoryPrefix(contextName: "MyApp"), "MA")
        XCTAssertEqual(try StreamNaming.categoryPrefix(contextName: "BillingContext"), "BC")
    }

    /// uppercaseLetters reproduces OC's hand-written `"OC\(Self.self)"` category WITHOUT the old Opportunity→OC alias.
    func testReproducesOCWithoutAlias() throws {
        XCTAssertEqual(try StreamNaming.categoryPrefix(contextName: "OpportunityContext"), "OC")
    }

    func testProjectionAndSourceDerived() throws {
        XCTAssertEqual(try StreamNaming.projectionPrefix(contextName: "IAMContext"), "IAMC_")
        XCTAssertEqual(try StreamNaming.sourceCategory(contextName: "IAMContext"), "IAMC")
        XCTAssertEqual(try StreamNaming.projectionPrefix(contextName: "OpportunityContext"), "OC_")
    }

    func testContextAloneThrows() {
        XCTAssertThrowsError(try StreamNaming.categoryPrefix(contextName: "Context")) { err in
            XCTAssertTrue("\(err)".contains("must not equal"),
                          "Context-alone must be rejected with the original message; got \(err)")
        }
    }

    func testAllLowercaseThrows() {
        XCTAssertThrowsError(try StreamNaming.categoryPrefix(contextName: "myapp")) { err in
            XCTAssertTrue("\(err)".contains("no uppercase"),
                          "all-lowercase name must be rejected; got \(err)")
        }
    }
}
