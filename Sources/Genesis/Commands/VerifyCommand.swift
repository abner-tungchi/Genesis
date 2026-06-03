import ArgumentParser
import Foundation
import GenesisCore

/// Phase 1.y: the release/CI gate that restores the "no unfilled domain logic ships" guarantee #error
/// used to give at compile time. Run inside a generated project root. Fails (exit 2) if any GenesisTODO
/// marker remains OR if any aggregate invariant errorCode has no enabled test referencing it.
struct VerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a generated project: no unfilled GenesisTODO holes remain, and every aggregate invariant has an enabled test."
    )

    @Option(name: .customLong("project-dir"), help: "Generated project root (default: cwd).")
    var projectDir: String?

    func run() async throws {
        let root = URL(fileURLWithPath: projectDir ?? FileManager.default.currentDirectoryPath)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
            print("✗ not a Swift package at \(root.path) (no Package.swift); run inside a generated project root or pass --project-dir")
            genesisExit(1)
            return
        }

        let result = VerifyChecker.verify(projectRoot: root)

        if !result.remainingMarkers.isEmpty {
            print("✗ \(result.remainingMarkers.count) unfilled domain hole(s) (GenesisTODO.notImplemented):")
            for h in result.remainingMarkers.prefix(40) { print("    \(h.file): \(h.snippet)") }
        }
        if !result.uncoveredInvariants.isEmpty {
            print("✗ \(result.uncoveredInvariants.count) declared invariant(s) with NO enabled test (honesty backstop):")
            for code in result.uncoveredInvariants { print("    .\(code) — add an enabled test that exercises it (no-op ensureInvariant is unverified without one)") }
        }

        if result.passed {
            print("✓ genesis verify passed: no unfilled holes, every invariant has an enabled test")
            return
        }
        genesisExit(2)
    }
}
