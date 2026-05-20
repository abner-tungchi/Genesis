import Foundation

struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum CLIRunner {
    static func productsDirectory() -> URL {
        #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("could not find the .xctest products directory")
        #else
        return Bundle.main.bundleURL
        #endif
    }

    static func genesisBinaryURL() -> URL {
        return productsDirectory().appendingPathComponent("genesis")
    }

    /// - environment: when non-nil, fully replaces the child process environment.
    ///   Pass a dict that includes at least PATH + HOME for the binary to behave normally.
    static func run(
        _ args: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> CLIResult {
        let binary = genesisBinaryURL()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NSError(
                domain: "CLIRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "genesis binary not found or not executable at \(binary.path) — build it first with `swift build`"]
            )
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = args
        if let cwd {
            process.currentDirectoryURL = cwd
        }
        if let environment {
            process.environment = environment
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return CLIResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    @discardableResult
    static func git(_ args: [String], cwd: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = cwd
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
