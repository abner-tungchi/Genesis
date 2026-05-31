import ArgumentParser
import Foundation
import GenesisCore

@main
struct Genesis: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genesis",
        abstract: "Bootstrap a Swift DDD/ES project from a Cosmogony Event Storming bundle.",
        version: GenesisCoreVersion.current,
        subcommands: [
            NewCommand.self,
            InstallSkillsCommand.self,
            CheckSkillsCommand.self,
            BundleParseCommand.self,
        ]
    )

    // Custom main: map GenesisError → exit codes 1/2/3 and treat all
    // ArgumentParser.ValidationError as exit 1 (user error, overrides default 64).
    // Manually invoke validate() before run() because the default main() path
    // doesn't expose a public hook to customize error → exit-code mapping.
    static func main() async {
        do {
            var command = try parseAsRoot()
            try command.validate()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as GenesisError {
            FileHandle.standardError.write(Data("✗ \(error.userMessage)\n".utf8))
            genesisExit(error.exitCode)
        } catch let error as ValidationError {
            FileHandle.standardError.write(Data("✗ \(error.message)\n".utf8))
            genesisExit(1)
        } catch {
            // Lean on ArgumentParser's built-in handler for --help / --version /
            // CleanExit / ExitCode / parser-level errors.
            Self.exit(withError: error)
        }
    }
}
