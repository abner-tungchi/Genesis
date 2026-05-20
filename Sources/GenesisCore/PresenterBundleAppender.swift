import Foundation

/// Errors raised by `PresenterBundleAppender.append`.
public enum PresenterAppendError: Error, Equatable, CustomStringConvertible {
    case invalidName(String, reason: String)
    case duplicateName(String)
    case unknownReadModel(String)
    case invalidOutputKind(String)
    case missingElementType
    case missingElementSource
    case invalidInputField(String, reason: String)

    public var description: String {
        switch self {
        case .invalidName(let name, let reason):
            return "invalid presenter name '\(name)': \(reason)"
        case .duplicateName(let name):
            return "duplicate presenter name '\(name)' already exists in bundle"
        case .unknownReadModel(let ref):
            return "readModelRef '\(ref)' not found in bundle.readModels[]; run /readmodel first"
        case .invalidOutputKind(let kind):
            return "invalid output kind '\(kind)'; must be 'array' | 'single' | 'scalar'"
        case .missingElementType:
            return "output.elementType is required and non-empty"
        case .missingElementSource:
            return "output.elementSource is required and non-empty"
        case .invalidInputField(let name, let reason):
            return "invalid input field '\(name)': \(reason)"
        }
    }
}

/// User answers from /presenter skill 5-step flow.
public struct PresenterAnswers: Sendable, Equatable, Codable {
    public let readModelRef: String
    public let name: String
    public let outputKind: String          // "array" | "single" | "scalar"
    public let elementType: String
    public let elementSource: String
    public let isOptional: Bool
    public let inputFields: [PresenterAnswerInputField]
    public let comment: String?
    public let overwriteIfExists: Bool

    public init(
        readModelRef: String,
        name: String,
        outputKind: String,
        elementType: String,
        elementSource: String,
        isOptional: Bool = false,
        inputFields: [PresenterAnswerInputField] = [],
        comment: String? = nil,
        overwriteIfExists: Bool = false
    ) {
        self.readModelRef = readModelRef
        self.name = name
        self.outputKind = outputKind
        self.elementType = elementType
        self.elementSource = elementSource
        self.isOptional = isOptional
        self.inputFields = inputFields
        self.comment = comment
        self.overwriteIfExists = overwriteIfExists
    }

    public struct PresenterAnswerInputField: Sendable, Equatable, Codable {
        public let name: String
        public let type: String
        public let fromPath: String?
        public init(name: String, type: String, fromPath: String? = nil) {
            self.name = name
            self.type = type
            self.fromPath = fromPath
        }
    }
}

public enum PresenterBundleAppender {

    public static let allowedOutputKinds: [String] = ["array", "single", "scalar"]

    public static func append(
        bundle: FullBundle,
        answers: PresenterAnswers
    ) throws -> FullBundle {
        try validateName(answers.name)
        try validateOutputKind(answers.outputKind)
        try validateElementType(answers.elementType)
        try validateElementSource(answers.elementSource)
        try validateInputFields(answers.inputFields)

        // readModelRef must exist
        guard let readModel = bundle.readModels.first(where: { $0.name == answers.readModelRef }) else {
            throw PresenterAppendError.unknownReadModel(answers.readModelRef)
        }

        // Duplicate name check
        let collision = bundle.presenters.first(where: { $0.name == answers.name })
        if collision != nil && !answers.overwriteIfExists {
            throw PresenterAppendError.duplicateName(answers.name)
        }

        // Build entry
        let aggregateRef = readModel.aggregateRef ?? "<context-level>"
        let inputFields = answers.inputFields.map {
            PresenterInputField(name: $0.name, type: $0.type, fromPath: $0.fromPath ?? $0.name)
        }
        // Default endpoint path: simple kebab using readModel.key.field as path param
        let kebabAgg = aggregateRef == "<context-level>" ? "context" : kebabCase(aggregateRef)
        let kebabPresenter = kebabCase(stripGetPrefix(answers.name))
        let pathParam = readModel.key?.field ?? "id"
        let defaultPath = "/\(kebabAgg)/{\(pathParam)}/\(kebabPresenter)"

        let entry = PresenterSpec(
            presenterSpecId: "p-\(answers.name)",
            name: answers.name,
            readModelRef: answers.readModelRef,
            aggregateRef: aggregateRef,
            input: PresenterInput(fields: inputFields),
            output: PresenterOutput(
                kind: PresenterOutputKind(rawValue: answers.outputKind)!,
                elementType: answers.elementType,
                elementSource: answers.elementSource,
                isOptional: answers.isOptional
            ),
            endpoint: PresenterEndpoint(path: defaultPath, method: "GET"),
            comment: answers.comment
        )

        var newPresenters = bundle.presenters
        if let idx = newPresenters.firstIndex(where: { $0.name == answers.name }) {
            newPresenters[idx] = entry
        } else {
            newPresenters.append(entry)
        }

        return FullBundle(
            manifestVersion: bundle.manifestVersion,
            bundleId: bundle.bundleId,
            context: bundle.context,
            aggregates: bundle.aggregates,
            useCases: bundle.useCases,
            dtos: bundle.dtos,
            readModels: bundle.readModels,
            presenters: newPresenters
        )
    }

    // MARK: - Validation

    private static func validateName(_ name: String) throws {
        let pattern = "^Get[A-Z][A-Za-z0-9]+$"
        let re = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: name.utf16.count)
        if re.firstMatch(in: name, range: range) == nil {
            throw PresenterAppendError.invalidName(name, reason: "must match \(pattern)")
        }
    }

    private static func validateOutputKind(_ kind: String) throws {
        if !allowedOutputKinds.contains(kind) {
            throw PresenterAppendError.invalidOutputKind(kind)
        }
    }

    private static func validateElementType(_ type: String) throws {
        if type.isEmpty {
            throw PresenterAppendError.missingElementType
        }
    }

    private static func validateElementSource(_ src: String) throws {
        if src.isEmpty {
            throw PresenterAppendError.missingElementSource
        }
    }

    private static func validateInputFields(_ fields: [PresenterAnswers.PresenterAnswerInputField]) throws {
        let pattern = "^[a-z][A-Za-z0-9]*$"
        let re = try NSRegularExpression(pattern: pattern)
        var seen = Set<String>()
        for f in fields {
            let r = NSRange(location: 0, length: f.name.utf16.count)
            if f.name.isEmpty || re.firstMatch(in: f.name, range: r) == nil {
                throw PresenterAppendError.invalidInputField(f.name, reason: "must match \(pattern)")
            }
            if !seen.insert(f.name).inserted {
                throw PresenterAppendError.invalidInputField(f.name, reason: "duplicate field name")
            }
            if f.type.isEmpty {
                throw PresenterAppendError.invalidInputField(f.name, reason: "type must be non-empty")
            }
        }
    }

    // MARK: - Helpers

    static func kebabCase(_ s: String) -> String {
        var result = ""
        for (i, ch) in s.enumerated() {
            if ch.isUppercase && i > 0 {
                result.append("-")
            }
            result.append(Character(ch.lowercased()))
        }
        return result
    }

    static func stripGetPrefix(_ name: String) -> String {
        if name.hasPrefix("Get") {
            return String(name.dropFirst("Get".count))
        }
        return name
    }
}
