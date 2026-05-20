import Foundation

public enum TemplateLoader {
    public static func loadPackageSwiftTemplate(version: String = "v0.1") throws -> String {
        try loadTemplate(name: "Package.swift", ext: "template", version: version)
    }

    /// Generic loader: looks up `Templates/<version>/<name>.<ext>` from the resource bundle.
    /// `name` and `ext` are split so that a template filename like `event.yaml.template` is
    /// loaded with name `event.yaml`, ext `template`.
    public static func loadTemplate(name: String, ext: String, version: String = "v0.1") throws -> String {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Templates/\(version)"
        ) else {
            throw GenesisError.fileSystemFailed(
                operation: "loadTemplate",
                underlying: "missing Templates/\(version)/\(name).\(ext) in resource bundle"
            )
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw GenesisError.fileSystemFailed(
                operation: "read template \(name).\(ext)",
                underlying: error.localizedDescription
            )
        }
    }
}
