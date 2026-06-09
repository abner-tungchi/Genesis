import XCTest
@testable import GenesisCore

/// M1 — DeployScriptRenderer: the generic projection-deploy + KurrentDB-bootstrap scripts that make
/// read-after-write actually work (deploy the codegen'd JS projections so read-model link streams populate).
final class DeployScriptRendererTests: XCTestCase {

    private func render(_ ctx: String) throws -> [(path: String, content: String, role: String)] {
        try DeployScriptRenderer.render(contextName: ctx)
    }

    func testEmitsExactlyTwoDeployScripts() throws {
        let outs = try render("IAMContext")
        XCTAssertEqual(outs.count, 2)
        XCTAssertEqual(Set(outs.map(\.path)), ["scripts/projection.sh", "scripts/start-kurrentdb.sh"])
        XCTAssertTrue(outs.allSatisfy { $0.role == "deploy-script" })
    }

    func testProjectionScriptIsGenericAndEnvOverridable() throws {
        let p = try XCTUnwrap(try render("IAMContext").first { $0.path == "scripts/projection.sh" }).content
        XCTAssertTrue(p.contains("projections/continuous"), "must POST continuous JS projections")
        XCTAssertTrue(p.contains("-name \"*Projection.js\""), "must glob projections/*Projection.js")
        // env-override form, NOT a bare literal (audit MF4); KDB_HOST tracks HTTP_PORT (review LOW fix)
        XCTAssertTrue(p.contains("KDB_HOST=\"${KDB_HOST:-http://localhost:${HTTP_PORT:-2113}}\""))
        XCTAssertFalse(p.contains("KDB_HOST=\"http://localhost:2113\""), "must use the override form, not bare literal")
        // zero per-context content in the projection deploy script
        XCTAssertFalse(p.contains("IAM"), "projection.sh must be generic — no context/aggregate content")
    }

    func testStartScriptProjectionsAllImageAndContextContainer() throws {
        let s = try XCTUnwrap(try render("IAMContext").first { $0.path == "scripts/start-kurrentdb.sh" }).content
        XCTAssertTrue(s.contains("EVENTSTORE_RUN_PROJECTIONS=All"), "KDB must run projections (server-side JS)")
        XCTAssertTrue(s.contains("docker.eventstore.com/kurrent-latest/kurrentdb:latest"), "full image path")
        XCTAssertTrue(s.contains("kurrentdb-iamcontext"), "container name parameterized by context")
        XCTAssertFalse(s.contains("__CONTEXT_KEBAB__"), "sentinel must be fully substituted")
        XCTAssertTrue(s.contains("CONTAINER=\"${CONTAINER:-"), "env-override form for container name")
    }

    func testContainerSuffixDerivation() {
        XCTAssertEqual(DeployScriptRenderer.containerSuffix(contextName: "OpportunityContext"), "opportunity-context")
        XCTAssertEqual(DeployScriptRenderer.containerSuffix(contextName: "IAMContext"), "iamcontext")
        XCTAssertEqual(DeployScriptRenderer.containerSuffix(contextName: "BillingContext"), "billing-context")
    }
}
