import ArgumentParser
import Foundation
import GenesisCore

struct NewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Bootstrap a Swift DDD project from a Cosmogony bundle."
    )

    @Argument(help: "Pascal-cased context name (e.g. IAMContext).")
    var contextName: String

    @Option(name: .customLong("from-bundle"), help: "Path to Cosmogony bundle JSON.")
    var fromBundle: String

    @Option(name: .customLong("adapter"), help: "Path to swift-adapter.yaml (optional).")
    var adapterFlag: String?

    @Option(name: .customLong("output"), help: "Output directory (default: current).")
    var output: String?

    @Flag(name: .customLong("no-git"), help: "Skip git pre-flight checks.")
    var noGit: Bool = false

    @Flag(name: .customLong("skip-build"), help: "Skip swift build validation after generation (resolve still runs).")
    var skipBuild: Bool = false

    func run() async throws {
        // Phase 0: input sanity
        let regex = try NSRegularExpression(pattern: "^[A-Z][A-Za-z0-9]*$")
        let nameRange = NSRange(contextName.startIndex..., in: contextName)
        if regex.firstMatch(in: contextName, range: nameRange) == nil {
            throw GenesisError.contextNameInvalid(value: contextName)
        }
        if fromBundle.isEmpty {
            throw GenesisError.bundleInvalid(reason: "--from-bundle path cannot be empty")
        }

        // Phase 1: read-only — parse bundle + adapter
        let outputURL = URL(fileURLWithPath: output ?? FileManager.default.currentDirectoryPath)
        let bundleURL = URL(fileURLWithPath: fromBundle)
        let bundle = try BundleParser.parseFull(at: bundleURL)

        if bundle.context != contextName {
            FileHandle.standardError.write(Data(
                "⚠️ ContextName mismatch: CLI arg '\(contextName)' overrides bundle.context '\(bundle.context)'\n".utf8
            ))
        }

        let adapterProvided = (adapterFlag != nil)
        let adapter: Adapter
        if let adapterPath = adapterFlag {
            adapter = try AdapterYamlParser.parse(
                at: URL(fileURLWithPath: adapterPath),
                contextName: contextName,
                bundleId: bundle.bundleId
            )
        } else {
            adapter = .defaultFor(contextName: contextName)
        }
        try AdapterApplier.validate(adapter: adapter, bundle: bundle)

        // Phase 2: render in memory + tag every file with its role
        let writer = SourceWriter(root: outputURL)
        var taggedFiles: [(path: String, content: String, role: String)] = []

        func plan(_ path: String, _ content: String, _ role: String) throws {
            try writer.plan(relativePath: path, content: content)
            taggedFiles.append((path, content, role))
        }

        // 2.1 Package.swift
        let pkg = try PackageRenderer.render(
            bundle: bundle,
            contextName: contextName,
            genesisVersion: GenesisCoreVersion.current,
            adapter: adapter
        )
        try plan(pkg.path, pkg.content, "package")

        // 2.2 Per-aggregate files (+ per-UC)
        for aggregate in bundle.aggregates {
            for file in try AggregateRenderer.render(
                spec: aggregate,
                bundle: bundle,
                adapter: adapter,
                contextName: contextName
            ) {
                try plan(file.path, file.content, file.role)
            }
        }

        // 2.3 Shared target (Phase 1.f: always emitted — infra files are universal)
        let needShared = true
        if needShared {
            for file in try SharedTargetRenderer.render(bundle: bundle, contextName: contextName, adapter: adapter) {
                try plan(file.path, file.content, file.role)
            }
        }

        // 2.3.1 ReadModel renderer (Phase 1.g — per-aggregate; 1.g.2 — cross-aggregate)
        let existingPresenterPaths = Self.scanExistingPresenterPaths(outputDir: outputURL, bundle: bundle, contextName: contextName)
        for file in try ReadModelRenderer.render(
            bundle: bundle,
            contextName: contextName,
            adapter: adapter,
            existingPresenterPaths: existingPresenterPaths
        ) {
            try plan(file.path, file.content, file.role)
        }

        // 2.3.2 Context-level projection-model + event-gen-config (Phase 1.g.2)
        for file in try ContextProjectionModelRenderer.render(bundle: bundle, contextName: contextName) {
            try plan(file.path, file.content, file.role)
        }

        // 2.3.3 API scaffolds (Phase 1.h — ApplicationService + DTO mappers per UC/DTO)
        let existingApiPaths = Self.scanExistingApiPaths(outputDir: outputURL, bundle: bundle)
        for file in try ApiRenderer.render(
            bundle: bundle,
            contextName: contextName,
            adapter: adapter,
            existingPaths: existingApiPaths
        ) {
            try plan(file.path, file.content, file.role)
        }

        // 2.3.3b Presenter scaffolds (Phase 1.k — read-side AS per bundle.presenters[])
        for file in try PresenterRenderer.render(
            bundle: bundle,
            contextName: contextName,
            adapter: adapter,
            existingPaths: existingApiPaths
        ) {
            try plan(file.path, file.content, file.role)
        }

        // 2.3.4 OpenAPI yaml + generator config (Phase 1.i — per write-UC aggregate)
        for file in try OpenApiYamlRenderer.render(
            bundle: bundle,
            contextName: contextName,
            adapter: adapter,
            existingPaths: existingApiPaths
        ) {
            try plan(file.path, file.content, file.role)
        }

        // 2.3.5 ApiHandler + ApiComponents+ApiError (Phase 1.i — per write-UC aggregate)
        for file in try ApiHandlerRenderer.render(
            bundle: bundle,
            contextName: contextName,
            adapter: adapter,
            existingPaths: existingApiPaths
        ) {
            try plan(file.path, file.content, file.role)
        }

        // 2.3.6 QueryError emission (Phase 1.k.2 — per-agg + context-level for read presenters)
        for file in try QueryErrorRenderer.render(
            bundle: bundle,
            contextName: contextName,
            existingPaths: existingApiPaths
        ) {
            try plan(file.path, file.content, file.role)
        }

        // 2.4 Test placeholder
        let testTemplate = try TemplateLoader.loadTemplate(name: "TestPlaceholder.swift", ext: "template")
        let testRendered = TemplateRenderer.render(template: testTemplate, vars: ["ContextName": contextName])
        try plan("Tests/\(contextName)Tests/PlaceholderTests.swift", testRendered.output, "testPlaceholder")

        // 2.5 Business docs (per aggregate)
        let generatedDate = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        for aggregate in bundle.aggregates {
            for file in try BusinessDocRenderer.render(
                spec: aggregate,
                bundle: bundle,
                adapter: adapter,
                contextName: contextName,
                generatedDate: generatedDate
            ) {
                try plan(file.path, file.content, file.role)
            }
        }

        // 2.6 Context-level docs (conventions + starter adapter if --adapter not provided)
        for file in try ContextLevelRenderer.render(
            bundle: bundle,
            contextName: contextName,
            adapter: adapter,
            adapterProvided: adapterProvided
        ) {
            try plan(file.path, file.content, file.role)
        }

        // 2.7 README + CLAUDE
        let readme = try ReadmeRenderer.renderReadme(
            bundle: bundle, contextName: contextName, genesisVersion: GenesisCoreVersion.current
        )
        try plan(readme.path, readme.content, "readme")
        let claudeMd = try ReadmeRenderer.renderClaudeMd(
            bundle: bundle, contextName: contextName, genesisVersion: GenesisCoreVersion.current
        )
        try plan(claudeMd.path, claudeMd.content, "readme")

        // 2.8 Manifest (last; not in its own generatedFiles[])
        let manifest = try ManifestRenderer.render(
            bundle: bundle,
            contextName: contextName,
            genesisVersion: GenesisCoreVersion.current,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            files: taggedFiles
        )
        try writer.plan(relativePath: manifest.path, content: manifest.content)

        // Phase 3: lightweight fs check (single gate)
        let didExistBefore = FileManager.default.fileExists(atPath: outputURL.path)
        var dirCreatedByThisRun = false

        if didExistBefore {
            // Phase 1.e: manifest-version sanity check — refuse to overwrite a dir bootstrapped by
            // an incompatible Genesis template version (e.g. Phase 1.b/1.c layout has flat aggregate
            // path; Phase 1.e moves to Entity/). Run BEFORE checkNoConflicts so the user gets a clear
            // version-mismatch message instead of a path-conflict error.
            try checkExistingManifestVersion(outputURL: outputURL, contextName: contextName)
            try writer.checkNoConflicts()
        }

        // Phase 4: mutation with rollback
        do {
            if !didExistBefore {
                do {
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                    dirCreatedByThisRun = true
                } catch {
                    throw GenesisError.fileSystemFailed(
                        operation: "create output directory",
                        underlying: error.localizedDescription
                    )
                }
            }

            try GitPreflight.check(at: outputURL, skip: noGit)
            try writer.commit()

            // Phase 1.e Step 9: explicit resolve + build phases (separate GenesisError cases per failure).
            let resolve = ProcessRunner.run(
                executable: "swift",
                args: ["package", "resolve"],
                cwd: outputURL,
                timeout: 600  // 10min cold-fetch ceiling
            )
            if resolve.exitCode != 0 {
                throw GenesisError.swiftPackageResolveFailed(stderr: resolve.stderr)
            }

            if !skipBuild {
                let build = ProcessRunner.run(
                    executable: "swift",
                    args: ["build", "-c", "release"],
                    cwd: outputURL,
                    timeout: 900  // 15min cold-build ceiling
                )
                if build.exitCode != 0 {
                    throw GenesisError.swiftBuildFailed(stderr: build.stderr)
                }
            }

            print(
                "✓ Genesis: wrote \(writer.writtenFileCount) files for context \(contextName) "
                + "(\(bundle.aggregates.count) aggregates, \(bundle.useCases.count) use cases, "
                + "\(bundle.dtos.count) DTOs) to \(outputURL.path); manifest at "
                + ".ai/contexts/\(contextName)/.scaffold-manifest.json"
                + (skipBuild ? " (build skipped via --skip-build)" : "")
            )
        } catch {
            writer.rollback()
            if dirCreatedByThisRun {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: outputURL.path)) ?? []
                if contents.isEmpty {
                    try? FileManager.default.removeItem(at: outputURL)
                }
            }
            throw error
        }
    }

    /// Phase 1.e Step 11: refuse to overwrite a dir generated by an incompatible Genesis template version.
    /// Compares the existing `.ai/contexts/<ContextName>/.scaffold-manifest.json`'s `templateVersion`
    /// against `GenesisCoreVersion.current`. Mismatch → throw `outputDirHasConflict` with a clear hint.
    private func checkExistingManifestVersion(outputURL: URL, contextName: String) throws {
        let manifestURL = outputURL
            .appendingPathComponent(".ai")
            .appendingPathComponent("contexts")
            .appendingPathComponent(contextName)
            .appendingPathComponent(".scaffold-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }

        let data = try Data(contentsOf: manifestURL)
        struct ManifestVersionOnly: Decodable { let templateVersion: String? }
        let parsed = try? JSONDecoder().decode(ManifestVersionOnly.self, from: data)
        let existingVersion = parsed?.templateVersion ?? "<unknown>"
        if existingVersion != GenesisCoreVersion.current {
            throw GenesisError.outputDirHasConflict(
                path: outputURL,
                conflict:
                    ".ai/contexts/\(contextName)/.scaffold-manifest.json templateVersion='\(existingVersion)' "
                    + "is incompatible with current Genesis '\(GenesisCoreVersion.current)'. "
                    + "Genesis does not support in-place template migration; "
                    + "remove the directory or use a different --output."
            )
        }
    }


    private static func scanExistingPresenterPaths(outputDir: URL, bundle: FullBundle, contextName: String) -> Set<String> {
        // Phase 1.g scaffold-once: prevent regenerate from overwriting user-filled when() bodies.
        // Scans:
        //   - per-aggregate: outputDir/Sources/<Aggregate>Aggregate/Usecase/Projector/Get*/Get*Presenter.swift
        //   - cross-aggregate (Phase 1.g.2 audit H1): outputDir/Sources/<Context>/Projector/Get*/Get*Presenter.swift
        var result: Set<String> = []
        let fm = FileManager.default
        // Per-aggregate scan
        for agg in bundle.aggregates {
            let projectorDir = outputDir
                .appendingPathComponent("Sources")
                .appendingPathComponent("\(agg.name)Aggregate")
                .appendingPathComponent("Usecase")
                .appendingPathComponent("Projector")
            guard let entries = try? fm.contentsOfDirectory(atPath: projectorDir.path) else { continue }
            for entry in entries where entry.hasPrefix("Get") {
                let presenterFile = "Sources/\(agg.name)Aggregate/Usecase/Projector/\(entry)/\(entry)Presenter.swift"
                let absPath = projectorDir.appendingPathComponent(entry).appendingPathComponent("\(entry)Presenter.swift").path
                if fm.fileExists(atPath: absPath) {
                    result.insert(presenterFile)
                }
            }
        }
        // Cross-aggregate scan (Phase 1.g.2)
        let contextProjectorDir = outputDir
            .appendingPathComponent("Sources")
            .appendingPathComponent(contextName)
            .appendingPathComponent("Projector")
        if let entries = try? fm.contentsOfDirectory(atPath: contextProjectorDir.path) {
            for entry in entries where entry.hasPrefix("Get") {
                let presenterFile = "Sources/\(contextName)/Projector/\(entry)/\(entry)Presenter.swift"
                let absPath = contextProjectorDir.appendingPathComponent(entry).appendingPathComponent("\(entry)Presenter.swift").path
                if fm.fileExists(atPath: absPath) {
                    result.insert(presenterFile)
                }
            }
        }
        return result
    }

    private static func scanExistingApiPaths(outputDir: URL, bundle: FullBundle) -> Set<String> {
        // Phase 1.h scaffold-once for Adapter/<UC>/<UC>ApplicationService.swift + Adapter/Dto/<X>Dto+Domain.swift
        var result: Set<String> = []
        let fm = FileManager.default
        for agg in bundle.aggregates {
            // ApplicationService scan
            let adapterDir = outputDir
                .appendingPathComponent("Sources")
                .appendingPathComponent("\(agg.name)Aggregate")
                .appendingPathComponent("Adapter")
            if let entries = try? fm.contentsOfDirectory(atPath: adapterDir.path) {
                for entry in entries where !entry.hasPrefix(".") {
                    let subPath = adapterDir.appendingPathComponent(entry)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: subPath.path, isDirectory: &isDir)
                    if !isDir.boolValue { continue }
                    let asPath = "Sources/\(agg.name)Aggregate/Adapter/\(entry)/\(entry)ApplicationService.swift"
                    let abs = subPath.appendingPathComponent("\(entry)ApplicationService.swift").path
                    if fm.fileExists(atPath: abs) {
                        result.insert(asPath)
                    }
                }
            }
            // DTO mapper scan
            let dtoDir = adapterDir.appendingPathComponent("Dto")
            if let entries = try? fm.contentsOfDirectory(atPath: dtoDir.path) {
                for entry in entries where entry.hasSuffix("+Domain.swift") {
                    result.insert("Sources/\(agg.name)Aggregate/Adapter/Dto/\(entry)")
                }
            }
            // Phase 1.i additions: ApiHandler.swift + ApiComponents+<A>ApiError.swift + openapi.yaml + generator-config
            let aggRoot = outputDir
                .appendingPathComponent("Sources")
                .appendingPathComponent("\(agg.name)Aggregate")
            let apiHandlerPath = "Sources/\(agg.name)Aggregate/Adapter/ApiHandler.swift"
            if fm.fileExists(atPath: aggRoot.appendingPathComponent("Adapter/ApiHandler.swift").path) {
                result.insert(apiHandlerPath)
            }
            let apiComponentsPath = "Sources/\(agg.name)Aggregate/Adapter/ApiComponents/ApiComponents+\(agg.name)ApiError.swift"
            if fm.fileExists(atPath: aggRoot.appendingPathComponent("Adapter/ApiComponents/ApiComponents+\(agg.name)ApiError.swift").path) {
                result.insert(apiComponentsPath)
            }
            let openapiYamlPath = "Sources/\(agg.name)Aggregate/openapi.yaml"
            if fm.fileExists(atPath: aggRoot.appendingPathComponent("openapi.yaml").path) {
                result.insert(openapiYamlPath)
            }
            let openapiCfgPath = "Sources/\(agg.name)Aggregate/openapi-generator-config.yaml"
            if fm.fileExists(atPath: aggRoot.appendingPathComponent("openapi-generator-config.yaml").path) {
                result.insert(openapiCfgPath)
            }
            // Phase 1.k additions: per-presenter read-side AS scaffold
            for presenter in bundle.presenters where presenter.aggregateRef == agg.name {
                let presenterPath = "Sources/\(agg.name)Aggregate/Adapter/\(presenter.name)/\(presenter.name)ApplicationService.swift"
                let abs = aggRoot.appendingPathComponent("Adapter/\(presenter.name)/\(presenter.name)ApplicationService.swift").path
                if fm.fileExists(atPath: abs) {
                    result.insert(presenterPath)
                }
            }
            // Phase 1.k.2 additions: per-agg {A}QueryError.swift (when aggregate has read presenter)
            let queryErrorPath = "Sources/\(agg.name)Aggregate/\(agg.name)QueryError.swift"
            if fm.fileExists(atPath: aggRoot.appendingPathComponent("\(agg.name)QueryError.swift").path) {
                result.insert(queryErrorPath)
            }
        }

        // Phase 1.k.2: context-level Adapter scaffold + {Context}QueryError.swift
        let contextName = bundle.context
        let ctxRoot = outputDir.appendingPathComponent("Sources").appendingPathComponent(contextName)
        // context-level read-side AS per-presenter
        for presenter in bundle.presenters where presenter.aggregateRef == "<context-level>" {
            let presenterPath = "Sources/\(contextName)/Adapter/\(presenter.name)/\(presenter.name)ApplicationService.swift"
            let abs = ctxRoot.appendingPathComponent("Adapter/\(presenter.name)/\(presenter.name)ApplicationService.swift").path
            if fm.fileExists(atPath: abs) {
                result.insert(presenterPath)
            }
        }
        // context-level ApiHandler / ApiComponents / openapi.yaml / config
        let ctxHandlerPath = "Sources/\(contextName)/Adapter/ApiHandler.swift"
        if fm.fileExists(atPath: ctxRoot.appendingPathComponent("Adapter/ApiHandler.swift").path) {
            result.insert(ctxHandlerPath)
        }
        let ctxComponentsPath = "Sources/\(contextName)/Adapter/ApiComponents/ApiComponents+\(contextName)ApiError.swift"
        if fm.fileExists(atPath: ctxRoot.appendingPathComponent("Adapter/ApiComponents/ApiComponents+\(contextName)ApiError.swift").path) {
            result.insert(ctxComponentsPath)
        }
        let ctxOpenapiPath = "Sources/\(contextName)/openapi.yaml"
        if fm.fileExists(atPath: ctxRoot.appendingPathComponent("openapi.yaml").path) {
            result.insert(ctxOpenapiPath)
        }
        let ctxOpenapiCfgPath = "Sources/\(contextName)/openapi-generator-config.yaml"
        if fm.fileExists(atPath: ctxRoot.appendingPathComponent("openapi-generator-config.yaml").path) {
            result.insert(ctxOpenapiCfgPath)
        }
        let ctxQueryErrorPath = "Sources/\(contextName)/\(contextName)QueryError.swift"
        if fm.fileExists(atPath: ctxRoot.appendingPathComponent("\(contextName)QueryError.swift").path) {
            result.insert(ctxQueryErrorPath)
        }

        return result
    }
}
