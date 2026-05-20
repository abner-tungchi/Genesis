import Foundation
import CryptoKit

public enum ManifestRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        genesisVersion: String,
        exportedAt: String,
        files: [(path: String, content: String, role: String)]
    ) throws -> (path: String, content: String) {
        let entries = files
            .sorted { $0.path < $1.path }
            .map { ManifestEntry(path: $0.path, sha256: sha256Hex(of: $0.content), role: $0.role) }
        let manifest = Manifest(
            manifestVersion: 1,
            bundleId: bundle.bundleId,
            templateVersion: genesisVersion,
            exportedAt: exportedAt,
            generatedFiles: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw GenesisError.fileSystemFailed(
                operation: "encode manifest",
                underlying: error.localizedDescription
            )
        }
        let content = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        let path = ".ai/contexts/\(contextName)/.scaffold-manifest.json"
        return (path, content)
    }

    private static func sha256Hex(of content: String) -> String {
        let data = Data(content.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private struct ManifestEntry: Codable {
        let path: String
        let sha256: String
        let role: String
    }

    private struct Manifest: Codable {
        let manifestVersion: Int
        let bundleId: String
        let templateVersion: String
        let exportedAt: String
        let generatedFiles: [ManifestEntry]
    }
}
