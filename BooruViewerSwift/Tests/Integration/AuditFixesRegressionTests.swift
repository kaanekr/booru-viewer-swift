import XCTest
@testable import BooruViewer

private struct DummyHTTPClient: HTTPClientProtocol {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw BooruError.network("unused")
    }
}

private actor InMemorySearchHistory: SearchHistoryStoring {
    private var entries: [String] = []

    func list() async throws -> [String] { entries }

    func record(_ query: String) async throws {
        entries.insert(query, at: 0)
    }
}

private final class PageRecordingSource: BooruSource, @unchecked Sendable {
    let id: SourceID
    let displayName: String
    let supportsVideo = true

    private let lock = NSLock()
    private var pages: [Int] = []
    private let pageBuilder: @Sendable (Int) -> [BooruPost]

    init(id: SourceID = .gelbooru, displayName: String = "Gelbooru", pageBuilder: @escaping @Sendable (Int) -> [BooruPost]) {
        self.id = id
        self.displayName = displayName
        self.pageBuilder = pageBuilder
    }

    var requestedPages: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return pages
    }

    func fetchPosts(query: SearchQuery, page: Int, context: SourceContext) async throws -> PostPage {
        lock.lock()
        pages.append(page)
        lock.unlock()
        let items = pageBuilder(page)
        return PostPage(posts: items, nextPage: items.isEmpty ? nil : page + 1, hasMore: !items.isEmpty)
    }

    func tagSuggestions(prefix: String, context: SourceContext) async throws -> [BooruTagSuggestion] {
        []
    }

    func resolveMedia(for post: BooruPost, context: SourceContext) async throws -> ResolvedMedia {
        ResolvedMedia(
            imageURL: post.sampleURL ?? post.previewURL,
            videoURL: nil,
            isVideo: false,
            placeholderURL: post.previewURL
        )
    }
}

/// Regression coverage for photo quality, video controls/auto-hide, pagination,
/// live blacklist filtering, quick filters, and tag formatting fixes.
final class AuditFixesRegressionTests: XCTestCase {
    private func makePost(
        id: String = "1",
        sourceID: SourceID = .gelbooru,
        preview: String? = "https://img4.gelbooru.com/thumbnails/aa/bb/thumbnail_1.jpg",
        sample: String? = "https://img4.gelbooru.com/samples/aa/bb/sample_1.jpg",
        original: String? = "https://img4.gelbooru.com/images/aa/bb/1.png",
        fileExt: String? = "png",
        tags: BooruTagGroups = BooruTagGroups(general: ["1girl", "solo"]),
        allTags: [String] = ["1girl", "solo"]
    ) -> BooruPost {
        BooruPost(
            id: id,
            sourceID: sourceID,
            sourceName: sourceID.rawValue,
            title: nil,
            previewURL: preview.flatMap(URL.init(string:)),
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: sample.flatMap(URL.init(string:)),
            originalURL: original.flatMap(URL.init(string:)),
            width: 1200,
            height: 1600,
            aspectRatio: 0.75,
            rating: .safe,
            score: 10,
            favCount: 5,
            tags: tags,
            allTags: allTags,
            sourceLink: nil,
            fileExt: fileExt,
            fileSize: nil,
            createdAt: "2026-01-01T00:00:00Z",
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }

    private func makeContext(quality: ImageQuality = .auto) -> SourceContext {
        SourceContext(
            http: DummyHTTPClient(),
            proxy: ProxyConfig(),
            gelbooruAuth: nil,
            rule34Auth: nil,
            imageQuality: quality
        )
    }

    // MARK: - Grid cover & viewer image quality

    @MainActor
    func testPostCardCoverCandidatesPreferSampleForStaticBooruInAutoAndFull() {
        let staticPost = makePost()
        let autoCandidates = PostCardView.coverCandidates(for: staticPost, imageQuality: .auto)
        XCTAssertEqual(autoCandidates.first?.absoluteString, "https://img4.gelbooru.com/samples/aa/bb/sample_1.jpg")
        XCTAssertTrue(autoCandidates.contains { $0.absoluteString == "https://img4.gelbooru.com/thumbnails/aa/bb/thumbnail_1.jpg" })

        let fullCandidates = PostCardView.coverCandidates(for: staticPost, imageQuality: .full)
        XCTAssertEqual(fullCandidates.first?.absoluteString, "https://img4.gelbooru.com/samples/aa/bb/sample_1.jpg")

        let previewCandidates = PostCardView.coverCandidates(for: staticPost, imageQuality: .preview)
        XCTAssertEqual(previewCandidates.first?.absoluteString, "https://img4.gelbooru.com/thumbnails/aa/bb/thumbnail_1.jpg")

        let gifPost = makePost(
            sample: "https://img4.gelbooru.com/images/aa/bb/1.gif",
            original: "https://img4.gelbooru.com/images/aa/bb/1.gif",
            fileExt: "gif"
        )
        let gifCandidates = PostCardView.coverCandidates(for: gifPost, imageQuality: .auto)
        XCTAssertEqual(gifCandidates.first?.absoluteString, "https://img4.gelbooru.com/thumbnails/aa/bb/thumbnail_1.jpg")

        let videoPost = makePost(
            sample: "https://img4.gelbooru.com/images/aa/bb/1.mp4",
            original: "https://img4.gelbooru.com/images/aa/bb/1.mp4",
            fileExt: "mp4"
        )
        let videoCandidates = PostCardView.coverCandidates(for: videoPost, imageQuality: .auto)
        XCTAssertEqual(videoCandidates.first?.absoluteString, "https://img4.gelbooru.com/thumbnails/aa/bb/thumbnail_1.jpg")
    }

    @MainActor
    func testZoomableViewerImageChainProgressiveAndZoomUpgrade() {
        let post = makePost()
        let unresolved = ZoomableMediaView.imageRequestChain(
            post: post,
            media: nil,
            imageQuality: .auto,
            hasUpgradedToOriginal: false
        )
        XCTAssertTrue(unresolved.primary.isEmpty)
        XCTAssertEqual(unresolved.placeholder?.absoluteString, "https://img4.gelbooru.com/thumbnails/aa/bb/thumbnail_1.jpg")

        let media = ResolvedMedia(
            imageURL: post.sampleURL,
            videoURL: nil,
            isVideo: false,
            placeholderURL: post.previewURL
        )
        let normalAuto = ZoomableMediaView.imageRequestChain(
            post: post,
            media: media,
            imageQuality: .auto,
            hasUpgradedToOriginal: false
        )
        XCTAssertEqual(normalAuto.primary.map(\.absoluteString), ["https://img4.gelbooru.com/samples/aa/bb/sample_1.jpg"])
        XCTAssertEqual(normalAuto.placeholder?.absoluteString, "https://img4.gelbooru.com/thumbnails/aa/bb/thumbnail_1.jpg")

        let zoomedAuto = ZoomableMediaView.imageRequestChain(
            post: post,
            media: media,
            imageQuality: .auto,
            hasUpgradedToOriginal: true
        )
        XCTAssertEqual(
            zoomedAuto.primary.map(\.absoluteString),
            [
                "https://img4.gelbooru.com/images/aa/bb/1.png",
                "https://img4.gelbooru.com/samples/aa/bb/sample_1.jpg",
            ]
        )

        let zoomedPreview = ZoomableMediaView.imageRequestChain(
            post: post,
            media: media,
            imageQuality: .preview,
            hasUpgradedToOriginal: true
        )
        XCTAssertEqual(zoomedPreview.primary.map(\.absoluteString), ["https://img4.gelbooru.com/samples/aa/bb/sample_1.jpg"])

        // Only index 0 (the primary high-res URL) may short-circuit from cache.
        XCTAssertTrue(ZoomableMediaView.shouldEarlyReturnFromCache(candidateIndex: 0))
        XCTAssertFalse(ZoomableMediaView.shouldEarlyReturnFromCache(candidateIndex: 1))
    }

    // MARK: - Video auto-hide rule

    @MainActor
    func testVideoControlsAutoHideOnlyWhenActivelyPlayingAndUnblocked() {
        XCTAssertTrue(
            ZoomableMediaView.shouldAutoHideVideoControls(
                isActive: true,
                showsControls: true,
                isPlaying: true,
                isScrubbing: false,
                isInfoPresented: false,
                loadFailed: false
            )
        )
        XCTAssertFalse(
            ZoomableMediaView.shouldAutoHideVideoControls(
                isActive: true,
                showsControls: true,
                isPlaying: false,
                isScrubbing: false,
                isInfoPresented: false,
                loadFailed: false
            )
        )
        XCTAssertFalse(
            ZoomableMediaView.shouldAutoHideVideoControls(
                isActive: true,
                showsControls: true,
                isPlaying: true,
                isScrubbing: true,
                isInfoPresented: false,
                loadFailed: false
            )
        )
        XCTAssertFalse(
            ZoomableMediaView.shouldAutoHideVideoControls(
                isActive: true,
                showsControls: true,
                isPlaying: true,
                isScrubbing: false,
                isInfoPresented: true,
                loadFailed: false
            )
        )
        XCTAssertFalse(
            ZoomableMediaView.shouldAutoHideVideoControls(
                isActive: true,
                showsControls: true,
                isPlaying: true,
                isScrubbing: false,
                isInfoPresented: false,
                loadFailed: true
            )
        )
        XCTAssertFalse(
            ZoomableMediaView.shouldAutoHideVideoControls(
                isActive: false,
                showsControls: true,
                isPlaying: true,
                isScrubbing: false,
                isInfoPresented: false,
                loadFailed: false
            )
        )
    }

    // MARK: - Search pagination & Add +tag

    @MainActor
    func testSearchPaginationDoesNotSkipOddPagesAndAddModeOmitsLiteralPlus() async throws {
        let source = PageRecordingSource { page in
            [
                BooruPost(
                    id: "p_\(page)",
                    sourceID: .gelbooru,
                    sourceName: "Gelbooru",
                    title: nil,
                    previewURL: URL(string: "https://img4.gelbooru.com/thumbnails/aa/bb/thumbnail_\(page).jpg"),
                    previewFallbackURL: nil,
                    previewVideoURL: nil,
                    previewThumbURL: nil,
                    previewThumbs: nil,
                    sampleURL: URL(string: "https://img4.gelbooru.com/samples/aa/bb/sample_\(page).jpg"),
                    originalURL: nil,
                    width: 800,
                    height: 1000,
                    aspectRatio: 0.8,
                    rating: .safe,
                    score: page,
                    favCount: 0,
                    tags: BooruTagGroups(general: ["tag1"]),
                    allTags: ["tag1"],
                    sourceLink: nil,
                    fileExt: "jpg",
                    fileSize: nil,
                    createdAt: "2026-01-01T00:00:00Z",
                    niches: nil,
                    isPremium: nil,
                    pageCount: nil,
                    mediaId: nil
                )
            ]
        }
        let vm = SearchViewModel(
            sourceID: .gelbooru,
            context: makeContext(),
            historyStore: InMemorySearchHistory(),
            sourceProvider: { _ in source }
        )

        func waitForIdle() async throws {
            for _ in 0..<200 {
                if !vm.isLoading && !vm.isLoadingMore { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        vm.search(text: "miku", mode: .replace)
        try await waitForIdle()
        vm.loadMore()
        try await waitForIdle()
        vm.loadMore()
        try await waitForIdle()
        vm.loadMore()
        try await waitForIdle()

        XCTAssertEqual(source.requestedPages, [1, 2, 3, 4])
        XCTAssertEqual(vm.results.map(\.id), ["p_1", "p_2", "p_3", "p_4"])

        vm.search(text: "solo", mode: .add)
        try await waitForIdle()
        XCTAssertEqual(vm.filter.tags, ["miku", "solo"])
        XCTAssertEqual(vm.query, "miku solo")
    }

    // MARK: - Feed live blacklist

    @MainActor
    func testFeedViewModelUpdateBlacklistFiltersAndRestoresLive() async {
        let p1 = makePost(id: "1", tags: BooruTagGroups(general: ["landscape"]), allTags: ["landscape"])
        let p2 = makePost(id: "2", tags: BooruTagGroups(general: ["watermark"]), allTags: ["watermark"])
        let source = PageRecordingSource { page in page == 1 ? [p1, p2] : [] }
        let vm = FeedViewModel(
            sourceID: .gelbooru,
            context: makeContext(),
            blacklistedTags: [],
            sourceProvider: { _ in source }
        )

        await vm.loadInitialIfNeeded()
        XCTAssertEqual(vm.posts.map(\.id), ["1", "2"])

        vm.updateBlacklist(["watermark"])
        XCTAssertEqual(vm.posts.map(\.id), ["1"])

        vm.updateBlacklist([])
        XCTAssertEqual(vm.posts.map(\.id), ["1", "2"])
    }

    // MARK: - HentaiHaven quick filters, Info tag tokens, cross-source uniqueKey

    func testHentaiHavenQuickFiltersTrackSectionDistinctFromLatest() {
        let options = SourceQuickFilters.options(for: .hentaihaven, context: .feed)
        let latest = options.first { $0.id == "latest" }!
        let trending = options.first { $0.id == "trending" }!

        let trendingFilter = SearchFilterConfig(hentaiHavenSection: .trending)
        XCTAssertFalse(SourceQuickFilters.isActive(latest, in: trendingFilter))
        XCTAssertTrue(SourceQuickFilters.isActive(trending, in: trendingFilter))

        let savedEpisodes = FeedOrder(sortBy: .default, timeRange: .all, hentaiHavenSection: .episodes)
        let normalized = SourceQuickFilters.normalizedFeedOrder(for: .hentaihaven, saved: savedEpisodes)
        XCTAssertEqual(normalized.hentaiHavenSection, .episodes)
    }

    @MainActor
    func testPostInfoFormattedSearchTokenAppliesPerSourceSyntax() {
        XCTAssertEqual(
            PostInfoSheetView.formattedSearchToken(for: "Studio X", category: .artist, sourceID: .redgifs),
            "user:Studio X"
        )
        XCTAssertEqual(
            PostInfoSheetView.formattedSearchToken(for: "Example Artist", category: .artist, sourceID: .nhentai),
            "artist:\"Example Artist\""
        )
        XCTAssertEqual(
            PostInfoSheetView.formattedSearchToken(for: "Big Breasts", category: .general, sourceID: .hentaihaven),
            "tag:\"big breasts\""
        )
        XCTAssertEqual(
            PostInfoSheetView.formattedSearchToken(for: "hatsune_miku", category: .character, sourceID: .gelbooru),
            "hatsune_miku"
        )
    }

    func testCrossSourceUniqueKeyDiffersForSameID() {
        let gPost = makePost(id: "42", sourceID: .gelbooru)
        let dPost = makePost(id: "42", sourceID: .danbooru)
        XCTAssertNotEqual(gPost.uniqueKey, dPost.uniqueKey)
    }
}
