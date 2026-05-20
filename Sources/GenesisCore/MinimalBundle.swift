import Foundation

public struct MinimalBundle: Sendable, Equatable {
    public let manifestVersion: Int
    public let bundleId: String
    public let context: String

    public init(manifestVersion: Int, bundleId: String, context: String) {
        self.manifestVersion = manifestVersion
        self.bundleId = bundleId
        self.context = context
    }
}
