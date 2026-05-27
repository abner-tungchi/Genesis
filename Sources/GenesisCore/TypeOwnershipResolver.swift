import Foundation

public enum TypeOwnership: Sendable, Equatable {
    case contextShared
    case ownedBy(aggregateName: String)
}

public enum TypeOwnershipResolver {
    private static let contextLevelSentinel = "<context-level>"

    public static func resolve(
        bundle: FullBundle,
        adapter: Adapter
    ) -> (ownership: [String: TypeOwnership], warnings: [String]) {
        let dtoNames = Set(bundle.dtos.map(\.name))
        let adapterTypeNames = Set(adapter.customTypes.map(\.name))
        let knownTypes = dtoNames.union(adapterTypeNames)
        let aggregateNames = Set(bundle.aggregates.map(\.name))
        let dtoByName = dictionaryByName(bundle.dtos)

        var ownership: [String: TypeOwnership] = [:]
        var warnings: [String] = []

        for name in knownTypes.sorted() {
            if let dto = dtoByName[name] {
                // Phase A: relies on DtoSpec.isContextShared becoming Bool? in Step 2
                switch dto.isContextShared {
                case .some(true):
                    ownership[name] = .contextShared
                    continue

                case .some(false):
                    if let aggregateRef = dto.aggregateRef {
                        if aggregateNames.contains(aggregateRef) {
                            ownership[name] = .ownedBy(aggregateName: aggregateRef)
                            continue
                        }

                        warnings.append(
                            "\(name): aggregateRef '\(aggregateRef)' not found in bundle.aggregates; falling back to usage scan"
                        )
                    }

                case .none:
                    break
                }
            }

            let refs = usageRefs(for: name, bundle: bundle, knownTypes: knownTypes)
            switch refs.count {
            case 0:
                ownership[name] = .contextShared
                warnings.append("\(name): no usage detected in bundle; defaulted to contextShared")

            case 1:
                let aggregateName = refs.first!
                ownership[name] = .ownedBy(aggregateName: aggregateName)
                warnings.append(
                    "\(name): ownership auto-detected as \(aggregateName); "
                        + "consider marking explicit (isContextShared: false, aggregateRef: \"\(aggregateName)\") in bundle"
                )

            default:
                let aggregateList = refs.sorted().joined(separator: ", ")
                ownership[name] = .contextShared
                warnings.append(
                    "\(name): auto-shared from \(refs.count) aggregates (\(aggregateList)); "
                        + "consider marking explicit (isContextShared: true) in bundle"
                )
            }
        }

        return (ownership, warnings)
    }

    private static func dictionaryByName(_ dtos: [DtoSpec]) -> [String: DtoSpec] {
        var result: [String: DtoSpec] = [:]
        for dto in dtos where result[dto.name] == nil {
            result[dto.name] = dto
        }
        return result
    }

    private static func usageRefs(
        for typeName: String,
        bundle: FullBundle,
        knownTypes: Set<String>
    ) -> Set<String> {
        var refs: Set<String> = []

        for aggregate in bundle.aggregates {
            for field in aggregate.state {
                recordUsage(
                    rawType: field.rawType,
                    aggregateRef: aggregate.name,
                    typeName: typeName,
                    knownTypes: knownTypes,
                    refs: &refs
                )
            }
        }

        for useCase in bundle.useCases {
            for field in useCase.input {
                recordUsage(
                    rawType: field.rawType,
                    aggregateRef: useCase.aggregate,
                    typeName: typeName,
                    knownTypes: knownTypes,
                    refs: &refs
                )
            }
            for field in useCase.eventPayload {
                recordUsage(
                    rawType: field.rawType,
                    aggregateRef: useCase.aggregate,
                    typeName: typeName,
                    knownTypes: knownTypes,
                    refs: &refs
                )
            }
        }

        for presenter in bundle.presenters where presenter.aggregateRef != contextLevelSentinel {
            for field in presenter.input.fields {
                recordUsage(
                    rawType: field.type,
                    aggregateRef: presenter.aggregateRef,
                    typeName: typeName,
                    knownTypes: knownTypes,
                    refs: &refs
                )
            }
            recordUsage(
                rawType: presenter.output.elementType,
                aggregateRef: presenter.aggregateRef,
                typeName: typeName,
                knownTypes: knownTypes,
                refs: &refs
            )
        }

        for readModel in bundle.readModels {
            guard let aggregateRef = readModel.aggregateRef, aggregateRef != contextLevelSentinel else {
                continue
            }

            for field in readModel.storedFields {
                recordUsage(
                    rawType: field.type,
                    aggregateRef: aggregateRef,
                    typeName: typeName,
                    knownTypes: knownTypes,
                    refs: &refs
                )
            }

            if let key = readModel.key {
                recordUsage(
                    rawType: key.type,
                    aggregateRef: aggregateRef,
                    typeName: typeName,
                    knownTypes: knownTypes,
                    refs: &refs
                )
            }
        }

        return refs
    }

    private static func recordUsage(
        rawType: String,
        aggregateRef: String,
        typeName: String,
        knownTypes: Set<String>,
        refs: inout Set<String>
    ) {
        guard extractTypeName(rawType: rawType, knownTypes: knownTypes) == typeName else {
            return
        }
        refs.insert(aggregateRef)
    }

    private static func extractTypeName(rawType: String, knownTypes: Set<String>) -> String? {
        var t = rawType.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("?") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        for prefix in ["Set<", "Array<", "Optional<"] {
            if t.hasPrefix(prefix) && t.hasSuffix(">") {
                t = String(t.dropFirst(prefix.count).dropLast())
                return extractTypeName(rawType: t, knownTypes: knownTypes)
            }
        }
        if t.hasPrefix("[") && t.hasSuffix("]") {
            t = String(t.dropFirst().dropLast())
            return extractTypeName(rawType: t, knownTypes: knownTypes)
        }
        return knownTypes.contains(t) ? t : nil
    }
}
