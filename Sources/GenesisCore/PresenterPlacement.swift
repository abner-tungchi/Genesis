import Foundation

/// Where a presenter's read-side Adapter (read AS + ApiHandler + openapi) lives.
///
/// Phase 1.k.2 (audit M3): single source of truth used by PresenterRenderer,
/// QueryErrorRenderer, ApiHandlerRenderer, OpenApiYamlRenderer, PackageRenderer
/// to avoid placement decisions drifting across renderers.
public enum PresenterPlacement: Equatable {
    case aggregate(name: String)
    case context
}

public enum PresenterPlacementResolver {
    /// Resolve placement for every presenter in the bundle.
    ///
    /// `BundleParser.parseFull` already enforced `presenter.aggregateRef == resolvedReadModelAggregateRef`
    /// (D1 consistency), so here we trust `presenter.aggregateRef` and treat `"<context-level>"` as context placement.
    public static func placements(bundle: FullBundle) -> [(presenter: PresenterSpec, placement: PresenterPlacement)] {
        bundle.presenters.map { p in
            if p.aggregateRef == "<context-level>" {
                return (p, .context)
            }
            return (p, .aggregate(name: p.aggregateRef))
        }
    }

    /// True iff the bundle has at least one context-level presenter (i.e. context Adapter needs to be emitted).
    public static func hasContextLevelPresenter(bundle: FullBundle) -> Bool {
        bundle.presenters.contains { $0.aggregateRef == "<context-level>" }
    }

    /// Aggregates (by name) that hold at least one per-aggregate read presenter.
    public static func aggregatesWithReadPresenter(bundle: FullBundle) -> Set<String> {
        Set(
            bundle.presenters
                .filter { $0.aggregateRef != "<context-level>" }
                .map { $0.aggregateRef }
        )
    }

    /// For context-level presenters, collect unique source aggregates from the referenced readModels' events.
    /// Used by context-level ApiHandler to know which aggregate targets to import for error mapping.
    public static func contextSourceAggregates(bundle: FullBundle) -> [String] {
        let contextPresenters = bundle.presenters.filter { $0.aggregateRef == "<context-level>" }
        let readModelsByName = Dictionary(uniqueKeysWithValues: bundle.readModels.map { ($0.name, $0) })
        var seen = Set<String>()
        var ordered: [String] = []
        for p in contextPresenters {
            guard let rm = readModelsByName[p.readModelRef] else { continue }
            for ref in rm.eventRefs where !seen.contains(ref.sourceAggregate) {
                seen.insert(ref.sourceAggregate)
                ordered.append(ref.sourceAggregate)
            }
        }
        return ordered.sorted()
    }
}
