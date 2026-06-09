import Foundation

/// Emits the two GENERIC deploy scripts a generated project needs to make read-after-write actually work:
///   - `scripts/projection.sh`     — globs `projections/*Projection.js` and (re)creates each as a continuous JS
///                                    projection in KurrentDB (the step that populates read-model link streams).
///   - `scripts/start-kurrentdb.sh`— boots a local KurrentDB with `EVENTSTORE_RUN_PROJECTIONS=All`.
///
/// Per the projection-deploy consensus (crux: a GET read model is materialized on-demand from a deployed
/// server-side JS projection — NO Swift subscription loop needed). Genesis already codegens the `.js`, the
/// ReadModel, the Presenter and a runnable server; the ONLY missing artifact was the deploy pipeline — without
/// it the codegen'd `.js` never reaches KurrentDB and every read GET silently returns nil.
///
/// Both scripts are generic (zero per-aggregate content). `projection.sh` is emitted verbatim; `start-kurrentdb.sh`
/// only parameterizes the default container name by the context (a `__CONTEXT_KEBAB__` sentinel — NOT a `{Brace}`
/// token, to avoid colliding with the scripts' own bash `${VAR:-default}` expansions). Config is env-overridable.
/// Scripts are written 0644 (SourceWriter sets no exec bit); run them via `bash scripts/<name>.sh`.
public enum DeployScriptRenderer {
    public static func render(contextName: String) throws -> [(path: String, content: String, role: String)] {
        let projection = try TemplateLoader.loadTemplate(name: "Scripts/projection.sh", ext: "template")

        let kebab = containerSuffix(contextName: contextName)
        let startRaw = try TemplateLoader.loadTemplate(name: "Scripts/start-kurrentdb.sh", ext: "template")
        let start = startRaw.replacingOccurrences(of: "__CONTEXT_KEBAB__", with: kebab)

        return [
            ("scripts/projection.sh", projection, "deploy-script"),
            ("scripts/start-kurrentdb.sh", start, "deploy-script"),
        ]
    }

    /// Docker container-name suffix derived from the context: lowercase with a hyphen inserted at each
    /// lower→Upper boundary (`OpportunityContext` → `opportunity-context`; `IAMContext` → `iamcontext`, since the
    /// leading caps are consecutive). Deterministic and a valid docker name component.
    static func containerSuffix(contextName: String) -> String {
        var out = ""
        let chars = Array(contextName)
        for (i, c) in chars.enumerated() {
            if c.isUppercase, i > 0, !chars[i - 1].isUppercase {
                out.append("-")
            }
            out.append(Character(c.lowercased()))
        }
        return out
    }
}
