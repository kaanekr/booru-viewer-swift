import Foundation
import SwiftUI

/// One pushed tag search, initialised with the tag query and the source of the post it came from.
/// Going back returns to the previous content; tapping an active tag pushes another instance, so a
/// tag chain keeps the native back stack (RN `SearchDetailScreen.tsx`).
@MainActor
struct SearchDetailScreen: View {
    private let sourceID: SourceID
    private let tags: String
    private let context: SourceContext
    private let historyStore: any SearchHistoryStoring
    private let blacklistedTags: [String]
    private let baseFilter: SearchFilterConfig
    private let imageQuality: ImageQuality
    private let gridPreviewsEnabled: Bool
    /// App-level change counter for the request context; forwarded to the inner `SearchScreen`,
    /// which re-pushes its `SourceContext` when a Worker URL, API key, or quality edit lands.
    private let contextVersion: Int
    private let sourceProvider: SearchViewModel.SourceProvider
    private let onOpenPost: ([BooruPost], Int) -> Void

    @State private var model: SearchViewModel
    @State private var pushedTag: TagSearchTarget? = nil

    /// - Parameters:
    ///   - sourceID: source the pushed search runs against.
    ///   - tags: raw tag text of this search instance (`tags.join(" ")` from the RN route).
    ///   - baseFilter: structured options to keep; `tags` and `jumpToPage = 1` win.
    ///   - onOpenPost: opens the viewer at `index` inside the result list.
    init(
        sourceID: SourceID,
        tags: String,
        context: SourceContext,
        historyStore: any SearchHistoryStoring,
        blacklistedTags: [String] = [],
        baseFilter: SearchFilterConfig? = nil,
        imageQuality: ImageQuality = .auto,
        gridPreviewsEnabled: Bool = true,
        contextVersion: Int = 0,
        sourceProvider: @escaping SearchViewModel.SourceProvider = { SourceRegistry.source(for: $0) },
        onOpenPost: @escaping ([BooruPost], Int) -> Void = { _, _ in }
    ) {
        self.sourceID = sourceID
        self.tags = tags
        self.context = context
        self.historyStore = historyStore
        self.blacklistedTags = blacklistedTags
        self.imageQuality = imageQuality
        self.gridPreviewsEnabled = gridPreviewsEnabled
        self.contextVersion = contextVersion
        self.sourceProvider = sourceProvider
        self.onOpenPost = onOpenPost

        var config = baseFilter ?? SearchFilterConfig()
        config.tags = SearchViewModel.parseTags(tags)
        config.jumpToPage = 1
        self.baseFilter = config

        _model = State(initialValue: SearchViewModel(
            sourceID: sourceID,
            context: context,
            historyStore: historyStore,
            blacklistedTags: blacklistedTags,
            sourceProvider: sourceProvider,
            initialFilter: config
        ))
    }

    var body: some View {
        SearchScreen(
            activeSourceID: sourceID,
            context: context,
            historyStore: historyStore,
            blacklistedTags: blacklistedTags,
            imageQuality: imageQuality,
            gridPreviewsEnabled: gridPreviewsEnabled,
            contextVersion: contextVersion,
            sourceProvider: sourceProvider,
            initialFilter: baseFilter,
            onOpenTag: { tag in
                pushedTag = TagSearchTarget(sourceID: sourceID, tags: tag)
            },
            onOpenPost: onOpenPost
        )
        .navigationTitle(tags)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pushedTag) { target in
            SearchDetailScreen(
                sourceID: target.sourceID,
                tags: target.tags,
                context: context,
                historyStore: historyStore,
                blacklistedTags: blacklistedTags,
                baseFilter: baseFilter,
                imageQuality: imageQuality,
                gridPreviewsEnabled: gridPreviewsEnabled,
                contextVersion: contextVersion,
                sourceProvider: sourceProvider,
                onOpenPost: onOpenPost
            )
        }
    }
}

/// A tag tapped inside a pushed search. Identity is per push so the same tag can be opened twice.
struct TagSearchTarget: Hashable {
    var sourceID: SourceID
    var tags: String
    /// Makes two pushes of the same tag distinct destinations.
    private let pushID = UUID()

    init(sourceID: SourceID, tags: String) {
        self.sourceID = sourceID
        self.tags = tags
    }
}
