#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

/// Cross-platform process exit. Wrapped so callers in modules that inherit
/// `ParsableCommand.exit(...)` instance method don't have to fight name resolution.
public func genesisExit(_ code: Int32) -> Never {
    exit(code)
}
