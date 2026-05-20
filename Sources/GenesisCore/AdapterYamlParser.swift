import Foundation
import Yams

public enum AdapterYamlParser {
    public static func parse(at url: URL, contextName: String, bundleId: String) throws -> Adapter {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !exists {
            throw GenesisError.adapterNotFound(url)
        }
        if isDirectory.boolValue {
            throw GenesisError.adapterInvalid(reason: "path is a directory, not a YAML file: \(url.path)")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GenesisError.fileSystemFailed(operation: "read adapter", underlying: error.localizedDescription)
        }

        let yamlString = String(data: data, encoding: .utf8) ?? ""
        let decoded: Envelope
        do {
            decoded = try YAMLDecoder().decode(Envelope.self, from: yamlString)
        } catch {
            throw GenesisError.adapterInvalid(reason: "YAML parse error: \(error)")
        }

        guard decoded.adapterVersion == 1 else {
            throw GenesisError.adapterInvalid(
                reason: "unsupported adapterVersion: \(decoded.adapterVersion ?? -1); only 1 is supported"
            )
        }
        guard decoded.schemaVersion == 1 else {
            throw GenesisError.adapterInvalid(
                reason: "unsupported schemaVersion: \(decoded.schemaVersion ?? -1); only 1 is supported"
            )
        }
        guard let parsedContext = decoded.contextName else {
            throw GenesisError.adapterInvalid(reason: "missing required key: contextName")
        }
        if parsedContext != contextName {
            throw GenesisError.adapterIncompatible(
                reason: "contextName mismatch: adapter='\(parsedContext)' but CLI arg='\(contextName)'"
            )
        }
        if let parsedBundleId = decoded.bundleId, parsedBundleId != bundleId {
            throw GenesisError.adapterIncompatible(
                reason: "bundleId mismatch: adapter='\(parsedBundleId)' but bundle='\(bundleId)'"
            )
        }

        let split = decoded.aggregateSplit ?? RawAggregateSplit(strategy: "byBoundedContext", rootMap: nil)
        let strategy = split.strategy ?? "byBoundedContext"
        guard strategy == "byBoundedContext" else {
            throw GenesisError.adapterInvalid(
                reason: "aggregateSplit.strategy '\(strategy)' not supported; only 'byBoundedContext'"
            )
        }

        let rawIdStrategy = decoded.idStrategy ?? RawIdStrategy(kind: "direct", wrapper: nil)
        let idKindString = rawIdStrategy.kind ?? "direct"
        let idKind: IdStrategySpec.Kind
        switch idKindString {
        case "direct": idKind = .direct
        case "typedStruct": idKind = .typedStruct
        default:
            throw GenesisError.adapterInvalid(
                reason: "idStrategy.kind '\(idKindString)' not supported; only 'direct' or 'typedStruct'"
            )
        }
        if idKind == .typedStruct, (rawIdStrategy.wrapper ?? "").isEmpty {
            throw GenesisError.adapterInvalid(
                reason: "idStrategy.kind == typedStruct requires non-empty 'wrapper' field"
            )
        }

        let customTypes = try (decoded.customTypes ?? []).enumerated().map { idx, raw in
            try decodeCustomType(raw, idx: idx)
        }

        // Warn about parsed-but-unused fields (codex M5)
        warnIgnoredFields(decoded)

        return Adapter(
            adapterVersion: 1,
            schemaVersion: 1,
            contextName: contextName,
            bundleId: decoded.bundleId,
            typeMapping: decoded.typeMapping ?? [:],
            customTypes: customTypes,
            createdEventOverrides: decoded.createdEventOverrides ?? [:],
            aggregateSplit: AggregateSplitSpec(strategy: strategy, rootMap: split.rootMap ?? [:]),
            idStrategy: IdStrategySpec(kind: idKind, wrapper: rawIdStrategy.wrapper)
        )
    }

    private static func decodeCustomType(_ raw: RawCustomType, idx: Int) throws -> CustomTypeSpec {
        guard let name = raw.name, !name.isEmpty else {
            throw GenesisError.adapterInvalid(reason: "customTypes[\(idx)] missing required key 'name'")
        }
        guard let kindString = raw.kind else {
            throw GenesisError.adapterInvalid(reason: "customTypes[\(idx)] missing required key 'kind'")
        }
        guard let kind = CustomTypeSpec.Kind(rawValue: kindString) else {
            throw GenesisError.adapterInvalid(
                reason: "customTypes[\(idx)].kind '\(kindString)' not supported; expected valueObject / enum / identifier"
            )
        }
        switch kind {
        case .enum:
            guard let cases = raw.cases, !cases.isEmpty else {
                throw GenesisError.adapterInvalid(
                    reason: "customTypes[\(idx)] kind='enum' requires non-empty 'cases'"
                )
            }
            for c in cases {
                if !isValidSwiftIdentifier(c) {
                    throw GenesisError.adapterInvalid(
                        reason: "customTypes[\(idx)].cases contains invalid identifier '\(c)'"
                    )
                }
            }
            return CustomTypeSpec(name: name, kind: .enum, underlying: nil, cases: cases)
        case .valueObject, .identifier:
            guard let underlying = raw.underlying, !underlying.isEmpty else {
                throw GenesisError.adapterInvalid(
                    reason: "customTypes[\(idx)] kind='\(kindString)' requires non-empty 'underlying'"
                )
            }
            return CustomTypeSpec(name: name, kind: kind, underlying: underlying, cases: nil)
        }
    }

    private static func isValidSwiftIdentifier(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        if !(first.isLetter || first == "_") { return false }
        for c in s.dropFirst() where !(c.isLetter || c.isNumber || c == "_") { return false }
        return true
    }

    private static func warnIgnoredFields(_ env: Envelope) {
        func warn(_ name: String) {
            FileHandle.standardError.write(Data(
                "⚠️ swift-adapter.yaml: key '\(name)' is parsed but not applied in Phase 1.c. See Phase 1.d / Phase 3.\n".utf8
            ))
        }
        if env.payloadConventions != nil { warn("payloadConventions") }
        if env.testingConventions != nil { warn("testingConventions") }
        if env.imports != nil { warn("imports") }
        if env.skip != nil { warn("skip") }
    }

    private struct Envelope: Decodable {
        let adapterVersion: Int?
        let schemaVersion: Int?
        let contextName: String?
        let bundleId: String?
        let typeMapping: [String: String]?
        let customTypes: [RawCustomType]?
        let createdEventOverrides: [String: String]?
        let aggregateSplit: RawAggregateSplit?
        let idStrategy: RawIdStrategy?

        // Parsed-but-unused fields (warn-emitted)
        let payloadConventions: [String: String]?
        let testingConventions: [String: String]?
        let imports: [String: [String]]?
        let skip: RawSkip?
    }

    private struct RawCustomType: Decodable {
        let name: String?
        let kind: String?
        let underlying: String?
        let cases: [String]?
    }

    private struct RawAggregateSplit: Decodable {
        let strategy: String?
        let rootMap: [String: String]?
    }

    private struct RawIdStrategy: Decodable {
        let kind: String?
        let wrapper: String?
    }

    private struct RawSkip: Decodable {
        let usecases: [String]?
    }
}
