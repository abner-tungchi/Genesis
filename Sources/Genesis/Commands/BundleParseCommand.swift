import ArgumentParser
import Foundation
import GenesisCore

struct BundleParseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-parse",
        abstract: "Parse a Cosmogony bundle JSON and emit the canonical FullBundle as JSON to stdout."
    )

    @Argument(help: "Path to the bundle JSON file.")
    var bundlePath: String

    func run() async throws {
        let url = URL(fileURLWithPath: bundlePath)
        // Reuses the single authoritative parser — no parsing logic duplicated here.
        // BundleParser may emit derive warnings to stderr; stdout stays pure JSON.
        let bundle = try BundleParser.parseFull(at: url)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
