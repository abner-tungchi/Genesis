import Foundation

public enum AdapterApplier {
    public static func validate(adapter: Adapter, bundle: FullBundle) throws {
        let aggMap = Dictionary(uniqueKeysWithValues: bundle.aggregates.map { ($0.name, $0) })
        for (aggName, ucName) in adapter.createdEventOverrides {
            guard let agg = aggMap[aggName] else {
                throw GenesisError.adapterInvalid(
                    reason: "createdEventOverrides references aggregate '\(aggName)' not in bundle"
                )
            }
            let aggUseCases = bundle.useCases.filter { $0.aggregateSpecId == agg.aggregateSpecId }
            if !aggUseCases.contains(where: { $0.useCase == ucName }) {
                throw GenesisError.adapterInvalid(
                    reason: "createdEventOverrides[\(aggName)] = '\(ucName)' but no such useCase exists in that aggregate"
                )
            }
        }
    }

    public static func resolveCreatedUseCase(
        for aggregate: AggregateSpec,
        useCases: [UseCaseSpec],
        adapter: Adapter
    ) throws -> UseCaseSpec {
        if let ucName = adapter.createdEventOverrides[aggregate.name],
           let uc = useCases.first(where: { $0.useCase == ucName }) {
            return uc
        }
        return try fallbackResolve(for: aggregate, useCases: useCases)
    }

    private static func fallbackResolve(for aggregate: AggregateSpec, useCases: [UseCaseSpec]) throws -> UseCaseSpec {
        let targetName = "create\(aggregate.name)"
        if let uc = useCases.first(where: { $0.useCase == targetName }) {
            return uc
        }
        if let uc = useCases.first(where: { $0.emittedEvent.hasSuffix("Created") }) {
            return uc
        }
        let prefixes = ["register", "bootstrap", "open", "init"]
        if let uc = useCases.first(where: { uc in prefixes.contains(where: { uc.useCase.hasPrefix($0) }) }) {
            return uc
        }
        throw GenesisError.bundleInvalid(
            reason: """
                cannot identify Created use case for aggregate '\(aggregate.name)'. Tried:
                  1. useCase == 'create\(aggregate.name)'
                  2. emittedEvent ending in 'Created'
                  3. useCase starting with 'register'/'bootstrap'/'open'/'init'
                If none of these match your naming, add a swift-adapter.yaml override (createdEventOverrides) \
                or rename the bundle use case.
                """
        )
    }

    /// Resolve the typed-ID wrapper name for an aggregate, given the adapter's idStrategy.
    /// Returns nil when idStrategy.kind == direct, or when typedStruct (which is deprecated in Phase 1.e).
    public static func resolveIdWrapperName(for aggregate: AggregateSpec, adapter: Adapter) -> String? {
        guard adapter.idStrategy.kind == .typedStruct else { return nil }
        // Phase 1.e deprecation: gradyzhuo/swift-ddd-kit 0.3.0 enforces `Entity where ID == String`,
        // making typed-struct ID wrappers structurally incompatible (would violate ID == String constraint).
        // idStrategy.typedStruct is deprecated; fall back to direct (raw String id) and warn.
        FileHandle.standardError.write(Data(
            "⚠️ idStrategy.typedStruct is deprecated in Genesis (gradyzhuo kit enforces ID == String). Falling back to .direct for \(aggregate.name).\n"
                .utf8
        ))
        return nil
    }
}
