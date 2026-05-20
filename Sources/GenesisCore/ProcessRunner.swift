import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunner {
    public static func run(
        executable: String,
        args: [String],
        cwd: URL? = nil,
        timeout: TimeInterval? = nil
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + args
        if let cwd {
            process.currentDirectoryURL = cwd
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: "failed to launch \(executable): \(error.localizedDescription)"
            )
        }

        // Timeout: SIGTERM after `timeout` seconds, then SIGKILL after 3s grace.
        // Done via dispatch closures keeping a strong reference to the process; closures
        // become no-ops if the process has already exited (process.isRunning == false).
        // Track SIGTERM and SIGKILL separately so the stderr prefix doesn't overclaim when
        // SIGTERM alone sufficed (i.e. SIGKILL closure observed process already exited).
        let sigtermFlag = TimeoutFlag()
        let sigkillFlag = TimeoutFlag()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                sigtermFlag.fire()
                process.terminate()  // SIGTERM
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    guard process.isRunning else { return }
                    sigkillFlag.fire()
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        var stderr = String(data: errData, encoding: .utf8) ?? ""
        if sigtermFlag.didFire(), let timeout {
            let suffix = sigkillFlag.didFire() ? ", then SIGKILL after 3s grace" : ""
            stderr = "[timeout after \(Int(timeout))s; sent SIGTERM\(suffix)]\n" + stderr
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: stderr
        )
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private var _fired = false
    private let lock = NSLock()
    func fire() {
        lock.lock()
        _fired = true
        lock.unlock()
    }
    func didFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fired
    }
}
