import Foundation
import Observation

/// Drives the full-screen media viewer: per-post `ResolvedMedia` cache, recent-view
/// recording, favorite toggling and favorite-tag / blacklist pinning.
///
/// Mirrors RN `ImageViewerModal` state (src/components/ImageViewerModal.tsx) and the
/// tag menu actions of `PostInfoModal` (src/components/PostInfoModal.tsx).
@MainActor
@Observable
final class ViewerViewModel {
    // MARK: Inputs

    let posts: [BooruPost]
    /// Per-request dependencies handed to every `BooruSource`.
    let context: SourceContext

    // MARK: Observable state

    /// Index of the visible post. Kept in sync with the paged `TabView`.
    var currentIndex: Int
    /// Transient toast, cleared automatically after 2.2s (RN `setTimeout` 2200).
    var toastMessage: String?
    /// nhentai-style multi-page reader toggle. Only meaningful when the visible
    /// post is an nhentai gallery with more than one page.
    var isMangaMode = false

    private(set) var mediaByKey: [String: ResolvedMedia] = [:]
    private(set) var loadingKeys: Set<String> = []
    /// Gallery pages per post, resolved from the source (`NHentaiSource.galleryDetail`).
    private(set) var galleryPagesByKey: [String: [URL]] = [:]
    private(set) var resolvedTagsByKey: [String: (groups: BooruTagGroups, allTags: [String])] = [:]
    private(set) var loadingGalleryKeys: Set<String> = []
    private(set) var favoriteKeys: Set<String> = []
    private(set) var savingFavorite = false
    private(set) var pinnedTags: Set<String> = []
    private(set) var blacklistedTagNames: Set<String> = []

    /// HentaiHaven episodes per series post, resolved lazily from the source.
    private var episodesByKey: [String: [HentaiHavenEpisode]] = [:]
    /// Selected episode id per post key (`HentaiHavenEpisode.id`).
    private var selectedEpisodeIDByKey: [String: String] = [:]
    private var loadingEpisodeKeys: Set<String> = []

    /// Last watched HentaiHaven episode number per post id, passed in by the app
    /// layer (RN `lastHentaiHavenEpisodes`).
    var hentaiHavenLastEpisodes: [String: Int] = [:]
    /// Persists the episode the user picked so the next visit resumes it.
    @ObservationIgnored var onSaveHentaiHavenEpisode: (@Sendable (String, Int) -> Void)?
    /// Search-history store used by the info sheet's "Save to History" action.
    @ObservationIgnored let searchHistory: (any SearchHistoryStoring)?
    /// Query modifier used by the info sheet's search actions.
    @ObservationIgnored var onModifySearch: (@Sendable (TagSearchModification) -> Void)?

    /// Current favorite and blacklisted tags queried by the info sheet menu.
    var favoriteTagSet: Set<String> { pinnedTags }
    var blacklistedTagSet: Set<String> { blacklistedTagNames }

    // MARK: Dependencies

    @ObservationIgnored private let sourceProvider: @Sendable (SourceID) -> (any BooruSource)?
    @ObservationIgnored private let recentViews: (any RecentViewsStoring)?
    @ObservationIgnored private let favorites: (any FavoritesStoring)?
    @ObservationIgnored private let favoriteTagStore: (any TagListStoring)?
    @ObservationIgnored private let blacklistStore: (any TagListStoring)?

    /// Generation counter for `contains` checks (RN `favoriteRequestRef`,
    /// ImageViewerModal.tsx:130, 215-224).
    @ObservationIgnored private var favoriteRequest = 0
    /// Last post recorded in recent views, so the focused viewer does not rewrite
    /// the same entry on every re-render (ImageViewerModal.tsx:55-59).
    @ObservationIgnored private var lastRecordedKey: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(
        posts: [BooruPost],
        initialIndex: Int = 0,
        context: SourceContext,
        sourceProvider: @escaping @Sendable (SourceID) -> (any BooruSource)? = { SourceRegistry.source(for: $0) },
        recentViews: (any RecentViewsStoring)? = nil,
        favorites: (any FavoritesStoring)? = nil,
        favoriteTags: (any TagListStoring)? = nil,
        blacklistedTags: (any TagListStoring)? = nil,
        searchHistory: (any SearchHistoryStoring)? = nil,
        hentaiHavenLastEpisodes: [String: Int] = [:],
        onSaveHentaiHavenEpisode: (@Sendable (String, Int) -> Void)? = nil,
        onModifySearch: (@Sendable (TagSearchModification) -> Void)? = nil
    ) {
        self.posts = posts
        self.context = context
        self.sourceProvider = sourceProvider
        self.recentViews = recentViews
        self.favorites = favorites
        self.favoriteTagStore = favoriteTags
        self.blacklistStore = blacklistedTags
        self.searchHistory = searchHistory
        self.hentaiHavenLastEpisodes = hentaiHavenLastEpisodes
        self.onSaveHentaiHavenEpisode = onSaveHentaiHavenEpisode
        self.onModifySearch = onModifySearch
        self.currentIndex = posts.indices.contains(initialIndex) ? initialIndex : 0
    }

    // MARK: Current post

    var currentPost: BooruPost? {
        posts.indices.contains(currentIndex) ? posts[currentIndex] : posts.first
    }

    /// RN `isVideoPost` (src/utils/media.ts).
    nonisolated static func isVideoPost(_ post: BooruPost) -> Bool {
        !VideoCandidateSelector.videoCandidates(for: post).isEmpty
    }

    /// Multi-page gallery pages (nhentai / manga), resolved lazily per post and cached
    /// in `galleryPagesByKey`. Only nhentai galleries have pages: `previewThumbs` are
    /// video trailer frames (Pornhub) and must never be treated as a manga.
    func galleryPages(for post: BooruPost) -> [URL] {
        guard post.sourceID == .nhentai else { return [] }
        return galleryPagesByKey[postKey(post)] ?? []
    }

    /// True when the visible post has more than one gallery page to read.
    var canShowMangaMode: Bool {
        guard let post = currentPost else { return false }
        return galleryPages(for: post).count > 1
    }

    /// Share target: the post page first, then the media itself.
    func shareURL(for post: BooruPost) -> URL? {
        post.sourceLink ?? post.originalURL ?? post.sampleURL ?? post.previewURL
    }

    // MARK: HentaiHaven episodes

    /// Episodes of a HentaiHaven series post, newest first (RN `PostInfoModal`
    /// episode picker). Empty until `loadEpisodes` resolves them.
    func episodes(for post: BooruPost) -> [HentaiHavenEpisode] {
        episodesByKey[postKey(post)] ?? []
    }

    /// The episode currently streamed for `post`, or `nil` when unresolved.
    func selectedEpisode(for post: BooruPost) -> HentaiHavenEpisode? {
        let key = postKey(post)
        guard let episodeID = selectedEpisodeIDByKey[key] else { return nil }
        return episodesByKey[key]?.first { $0.id == episodeID }
    }

    /// Fetches the episode list once per post and starts streaming the resume
    /// episode (`hentaiHavenLastEpisodes[post.id]`) or the newest one.
    func loadEpisodes(for post: BooruPost) async {
        guard post.sourceID == .hentaihaven else { return }
        let key = postKey(post)
        guard episodesByKey[key] == nil, !loadingEpisodeKeys.contains(key) else { return }
        loadingEpisodeKeys.insert(key)
        defer { loadingEpisodeKeys.remove(key) }

        let source = (sourceProvider(post.sourceID) as? HentaiHavenSource) ?? HentaiHavenSource()
        do {
            let episodes = try await source.fetchEpisodes(for: post, context: context)
            guard !Task.isCancelled, !episodes.isEmpty else { return }
            episodesByKey[key] = episodes

            let lastNumber = hentaiHavenLastEpisodes[post.id]
            // `fetchEpisodes` is ordered ascending, so the newest episode is the default.
            let selected = episodes.first { $0.number == lastNumber } ?? episodes.last ?? episodes[0]
            selectedEpisodeIDByKey[key] = selected.id
            await streamEpisode(selected, for: post, source: source)
        } catch {
            return
        }
    }

    /// Switches the visible HentaiHaven post to `episode`, remembers the choice
    /// and resolves its stream URL immediately (RN `handleEpisodeSelect`).
    func selectEpisode(_ episode: HentaiHavenEpisode, for post: BooruPost) async {
        guard post.sourceID == .hentaihaven else { return }
        let key = postKey(post)
        selectedEpisodeIDByKey[key] = episode.id
        onSaveHentaiHavenEpisode?(post.id, episode.number)

        let source = (sourceProvider(post.sourceID) as? HentaiHavenSource) ?? HentaiHavenSource()
        await streamEpisode(episode, for: post, source: source)
    }

    /// Synchronous convenience for UI controls, launching stream resolution in a task.
    func selectEpisode(_ episode: HentaiHavenEpisode, for post: BooruPost) {
        guard post.sourceID == .hentaihaven else { return }
        let key = postKey(post)
        selectedEpisodeIDByKey[key] = episode.id
        onSaveHentaiHavenEpisode?(post.id, episode.number)

        Task { [weak self] in
            guard let self else { return }
            let source = (self.sourceProvider(post.sourceID) as? HentaiHavenSource) ?? HentaiHavenSource()
            await self.streamEpisode(episode, for: post, source: source)
        }
    }

    /// Resolves an episode's HLS/MP4 stream and caches it as the post's media,
    /// falling back to the episode thumbnail when the stream cannot be resolved.
    private func streamEpisode(
        _ episode: HentaiHavenEpisode,
        for post: BooruPost,
        source: HentaiHavenSource
    ) async {
        let key = postKey(post)
        let resolved = try? await source.resolveEpisodeStream(episode: episode, post: post, context: context)
        guard !Task.isCancelled else { return }
        let stream = (resolved ?? episode.streamURL).flatMap {
            HentaiHavenSource.isPlayableVideoURL($0) ? $0 : nil
        }
        let placeholder = ImageQualityResolver.placeholderURL(for: post)

        if let stream {
            mediaByKey[key] = ResolvedMedia(
                imageURL: episode.thumbnailURL ?? post.previewURL,
                videoURL: stream,
                isVideo: true,
                placeholderURL: placeholder
            )
        } else {
            mediaByKey[key] = ResolvedMedia(
                imageURL: episode.thumbnailURL ?? post.sampleURL ?? post.previewURL,
                videoURL: nil,
                isVideo: false,
                placeholderURL: placeholder
            )
        }
    }

    // MARK: Media resolution

    func resolvedTags(for post: BooruPost) -> (groups: BooruTagGroups, allTags: [String]) {
        resolvedTagsByKey[postKey(post)] ?? (post.tags, post.allTags)
    }

    func media(for post: BooruPost) -> ResolvedMedia? {
        mediaByKey[postKey(post)]
    }

    func isLoading(_ post: BooruPost) -> Bool {
        loadingKeys.contains(postKey(post))
    }

    /// Resolves and caches the gallery pages and tags of one post. Only nhentai has a paged
    /// gallery; a cancelled or failed load is deliberately left uncached so swiping
    /// back to the post retries instead of showing an empty reader forever.
    func loadGalleryPages(for post: BooruPost) async {
        guard post.sourceID == .nhentai else { return }
        let key = postKey(post)
        guard galleryPagesByKey[key] == nil, !loadingGalleryKeys.contains(key) else { return }
        loadingGalleryKeys.insert(key)
        defer { loadingGalleryKeys.remove(key) }

        let source = (sourceProvider(post.sourceID) as? NHentaiSource) ?? NHentaiSource()
        do {
            let detail = try await source.galleryDetail(for: post, context: context)
            guard !Task.isCancelled else { return }
            galleryPagesByKey[key] = detail.pages
            if !detail.allTags.isEmpty {
                resolvedTagsByKey[key] = (detail.tags, detail.allTags)
            }
            let isSamePost = currentPost.map { postKey($0) == key } ?? false
            if isSamePost, detail.pages.count > 1 {
                isMangaMode = true
            }
        } catch {
            return
        }
    }

    /// Resolves and caches the media for `post`. Falls back to the pure URL rules
    /// (`ImageQualityResolver` + `VideoCandidateSelector`) when the source cannot be
    /// resolved or fails, so the viewer always has something to show.
    func loadMedia(for post: BooruPost) async {
        let key = postKey(post)
        guard mediaByKey[key] == nil, !loadingKeys.contains(key) else { return }
        loadingKeys.insert(key)
        defer { loadingKeys.remove(key) }

        // nhentai's gallery detail is already fetched for the manga reader, so reuse it
        // instead of issuing the same request twice (`NHentaiSource.resolveMedia` uses
        // the same "first page, else listing cover" rule).
        if post.sourceID == .nhentai, let pages = galleryPagesByKey[key] {
            let resolved = ResolvedMedia(
                imageURL: pages.first ?? post.sampleURL ?? post.previewURL,
                videoURL: nil,
                isVideo: false,
                placeholderURL: ImageQualityResolver.placeholderURL(for: post)
            )
            guard let media = await playable(resolved, post: post) else { return }
            mediaByKey[key] = media
            return
        }

        if let source = sourceProvider(post.sourceID) {
            do {
                let resolved = try await source.resolveMedia(for: post, context: context)
                if let media = await playable(resolved, post: post) {
                    var finalMedia = media
                    if post.sourceID == .nhentai, !finalMedia.isVideo, finalMedia.imageURL == nil {
                        finalMedia = ResolvedMedia(
                            imageURL: post.sampleURL ?? post.previewURL,
                            videoURL: finalMedia.videoURL,
                            isVideo: finalMedia.isVideo,
                            placeholderURL: finalMedia.placeholderURL ?? ImageQualityResolver.placeholderURL(for: post)
                        )
                    }
                    mediaByKey[key] = finalMedia
                    return
                }
            } catch {
                // A cancelled load must not cache the fallback: leaving `mediaByKey[key]`
                // nil is what lets the post retry when the user swipes back to it.
                if error is CancellationError || Task.isCancelled { return }
            }
        }

        let fallback = Self.fallbackMedia(for: post, quality: context.imageQuality)
        if let media = await playable(fallback, post: post) {
            var finalMedia = media
            if post.sourceID == .nhentai, !finalMedia.isVideo, finalMedia.imageURL == nil {
                finalMedia = ResolvedMedia(
                    imageURL: post.sampleURL ?? post.previewURL,
                    videoURL: finalMedia.videoURL,
                    isVideo: finalMedia.isVideo,
                    placeholderURL: finalMedia.placeholderURL ?? ImageQualityResolver.placeholderURL(for: post)
                )
            }
            mediaByKey[key] = finalMedia
        } else if post.sourceID == .nhentai {
            mediaByKey[key] = ResolvedMedia(
                imageURL: post.sampleURL ?? post.previewURL,
                videoURL: nil,
                isVideo: false,
                placeholderURL: ImageQualityResolver.placeholderURL(for: post)
            )
        }
    }

    /// Prefetches the next two and previous one posts (ImageViewerModal.tsx:226-249).
    func prefetchNeighbors() {
        for offset in [1, 2, -1] {
            let index = currentIndex + offset
            guard posts.indices.contains(index) else { continue }
            let post = posts[index]
            Task {
                // nhentai pages first: `loadMedia` reuses the cached gallery detail.
                await loadGalleryPages(for: post)
                await loadMedia(for: post)
            }
        }
    }

    /// Pure image/video choice for one post, used when a source is unavailable.
    ///
    /// `VideoCandidateSelector` drops WebM on iOS (-11828), which would leave a
    /// Gelbooru / Rule34 / Danbooru / Yande.re / Realbooru `.webm` post with no video at
    /// all. A post's own WebM still feeds the `playable(_:for:)` upgrade, but no URL is
    /// invented here: a bare `.mp4` sibling is only taken once a HEAD probe confirms it.
    nonisolated static func fallbackMedia(for post: BooruPost, quality: ImageQuality) -> ResolvedMedia {
        // A Realbooru list row carries no file extension, so its `/images/<hash>.mp4` is a
        // thumbnail-hash guess, not a server statement: it is never offered as the video.
        let candidate = VideoCandidateSelector.videoCandidates(for: post)
            .first { !RealbooruSource.isThumbnailHashGuess($0, for: post) }
        let video = candidate
        var image = ImageQualityResolver.imageURL(for: post, quality: quality)
        // A video container is not a still: show the cover so the page never waits on a
        // file the image loader cannot decode.
        if let current = image, Self.isVideoContainer(current) {
            image = ImageQualityResolver.placeholderURL(for: post) ?? post.previewURL
        }
        if post.sourceID == .nhentai, image == nil {
            image = post.sampleURL ?? post.previewURL
        }
        return ResolvedMedia(
            imageURL: image,
            videoURL: video,
            isVideo: video != nil,
            placeholderURL: ImageQualityResolver.placeholderURL(for: post)
        )
    }

    /// The WebM file URL of the post itself. `VideoCandidateSelector` drops these on iOS,
    /// so the upgrade in `playable(_:for:)` reads the raw post fields instead: an explicit
    /// `.webm` on `originalURL` / `sampleURL` (or, except on Pornhub, `previewVideoURL`),
    /// or — for records whose `fileExt` is `webm` but whose URL field still ends in `.mp4`
    /// — that URL's WebM sibling.
    nonisolated static func webmMediaURL(for post: BooruPost) -> URL? {
        // A Pornhub `previewVideoURL` is the hover flipbook, not the main video: reading it
        // here would turn an unverified `.mp4` guess of that clip into the post's video.
        var raw = [post.originalURL, post.sampleURL]
        if post.sourceID != .pornhub {
            raw.append(post.previewVideoURL)
        }
        let fields = raw.map { MediaURLNormalizer.normalize($0, sourceID: post.sourceID) }
        if let explicit = fields.first(where: { $0.map(Self.isWebMPath) ?? false }) {
            return explicit
        }
        guard post.fileExt?.lowercased() == "webm" else { return nil }
        return fields.compactMap { $0 }.first.flatMap(Self.webmSibling)
    }

    /// `…/hash.mp4` → `…/hash.webm`: the file behind Realbooru's thumbnail-hash guess.
    private nonisolated static func webmSibling(of url: URL) -> URL? {
        let raw = url.absoluteString
        let pathEnd = raw.firstIndex { $0 == "?" || $0 == "#" } ?? raw.endIndex
        let path = raw[..<pathEnd]
        let suffix = raw[pathEnd...]
        guard path.lowercased().hasSuffix(".mp4") else { return nil }
        return URL(string: String(path.dropLast(".mp4".count)) + ".webm" + String(suffix))
    }

    /// WebM → MP4 upgrade (RN `checkMp4UpgradeAvailable`, ImageViewerModal.tsx) and
    /// `isVideo` kept consistent with the URL that actually survived. Returns `nil`
    /// when the surrounding task was cancelled, so the caller caches nothing.
    ///
    /// Only a URL the server actually named, or a `.mp4` sibling the server confirmed
    /// with a 2xx HEAD, may reach `AVPlayer`. A rejected HEAD (404/403) or a transport
    /// failure is "not proven", never "probably fine": the WebM stays on the post (and in
    /// the source's `ResolvedMedia`) while the viewer shows the post's still instead of
    /// handing the player a guessed URL that would spin forever.
    private func playable(_ resolved: ResolvedMedia, post: BooruPost) async -> ResolvedMedia? {
        if Task.isCancelled { return nil }
        var out = resolved
        // A WebM URL reaches the viewer two ways: a source may hand one back directly, or
        // the post's own fields carry it after `VideoCandidateSelector` dropped it on iOS.
        // Both run the same server-confirmed `.mp4` sibling probe.
        let webmFromMedia = out.videoURL.flatMap { video in Self.isWebMPath(video) ? video : nil }
        let webmFromPost = out.videoURL == nil ? Self.webmMediaURL(for: post) : nil
        if let webm = webmFromMedia ?? webmFromPost {
            out.videoURL = await Self.mp4URL(for: webm, http: context.http)
            // The probe is a network call: a cancelled viewer must not cache its result.
            if Task.isCancelled { return nil }
        }
        out.isVideo = out.videoURL != nil
        if out.placeholderURL == nil {
            out.placeholderURL = ImageQualityResolver.placeholderURL(for: post)
        }
        if !out.isVideo, out.imageURL == nil {
            out.imageURL = ImageQualityResolver.imageURL(for: post, quality: context.imageQuality)
        }
        // nhentai posts always have a cover: never surface "Media unavailable"
        // when the sample/preview URL can stand in for the gallery page.
        if post.sourceID == .nhentai, !out.isVideo, out.imageURL == nil {
            out.imageURL = post.sampleURL ?? post.previewURL
        }
        return out
    }

    private nonisolated static func isWebMPath(_ url: URL) -> Bool {
        let raw = url.absoluteString.lowercased()
        let path = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        return path.hasSuffix(".webm")
    }

    /// True when the URL names a video container, so it can never be decoded as a still.
    private nonisolated static func isVideoContainer(_ url: URL) -> Bool {
        let raw = url.absoluteString.lowercased()
        let path = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        return [".mp4", ".webm", ".mov", ".m4v", ".m3u8"].contains { path.hasSuffix($0) }
    }

    /// `.mp4` sibling of `webm`, accepted only when a HEAD request answers 200-299
    /// (media.ts:780-783).
    ///
    /// The optimistic `mp4CandidateURL` fallback RN keeps for HEAD-rejecting CDNs is
    /// deliberately gone: a 404/403 or a transport error proves nothing, and handing that
    /// guess to `AVPlayer` is the "permanent spinner" this task exists to remove. A
    /// byte-range validation is not available either — the transport
    /// (`URLSessionHTTPClient`) reads whole bodies, so it cannot guarantee a bounded fetch
    /// and would download megabytes just to test an extension. Unproven therefore returns
    /// nil; the caller shows the post's still and reports the codec limitation, not a
    /// broken URL.
    nonisolated static func mp4URL(for webm: URL, http: any HTTPClientProtocol) async -> URL? {
        await MP4Upgrade.upgradedURL(for: webm, http: http)
    }

    /// Everything the viewer needs when the visible page changes: record the view,
    /// re-read the favorite state, resolve media and prefetch neighbours
    /// (ImageViewerModal.tsx:157-249).
    func prepareCurrentPage() async {
        async let recordTask: Void = recordViewIfNeeded()
        async let favoriteTask: Void = refreshFavorite()
        if let post = currentPost {
            let key = postKey(post)
            if post.sourceID == .hentaihaven {
                await loadEpisodes(for: post)
            }
            await loadGalleryPages(for: post)
            // nhentai galleries open straight into the reader so the pages read
            // smoothly instead of a single cover (RN auto manga mode).
            let isSamePost = currentPost.map { postKey($0) == key } ?? false
            if post.sourceID == .nhentai, isSamePost, galleryPages(for: post).count > 1 {
                isMangaMode = true
            } else if !canShowMangaMode {
                isMangaMode = false
            }
            await loadMedia(for: post)
        }
        _ = await (recordTask, favoriteTask)
        prefetchNeighbors()
    }

    // MARK: Recent views

    /// Records the visible post once per navigation step (ImageViewerModal.tsx:55-59).
    func recordViewIfNeeded() async {
        guard let post = currentPost else { return }
        let key = postKey(post)
        guard lastRecordedKey != key else { return }
        lastRecordedKey = key
        guard let recentViews else { return }
        try? await recentViews.record(post)
    }

    // MARK: Favorites

    func isFavorite(_ post: BooruPost) -> Bool {
        favoriteKeys.contains(postKey(post))
    }

    /// Re-reads the favorite state of the visible post (ImageViewerModal.tsx:215-224).
    func refreshFavorite() async {
        guard let post = currentPost else { return }
        favoriteRequest += 1
        let request = favoriteRequest
        let key = postKey(post)
        favoriteKeys.remove(key)
        guard let favorites else { return }
        guard let value = try? await favorites.contains(post), request == favoriteRequest else { return }
        if value { favoriteKeys.insert(key) } else { favoriteKeys.remove(key) }
    }

    /// Toggles the visible post, guarding against double writes
    /// (ImageViewerModal.tsx:330-346).
    func toggleFavorite() async {
        guard let post = currentPost, let favorites, !savingFavorite else { return }
        let key = postKey(post)
        let wasFavorite = favoriteKeys.contains(key)
        savingFavorite = true
        defer { savingFavorite = false }
        do {
            if wasFavorite {
                try await favorites.remove(id: post.id, sourceID: post.sourceID)
                favoriteKeys.remove(key)
            } else {
                try await favorites.add(post)
                favoriteKeys.insert(key)
            }
        } catch {
            showToast("Could not save favorite. Your saved posts have not been changed.")
        }
    }

    // MARK: Tag lists

    /// Loads both tag lists once so the info sheet can show pinned/blacklisted state.
    func loadTagLists() async {
        if let favoriteTagStore, let tags = try? await favoriteTagStore.list() {
            pinnedTags = Set(tags.map(Self.favoriteTagKey))
        }
        if let blacklistStore, let tags = try? await blacklistStore.list() {
            blacklistedTagNames = Set(tags.map(Self.blacklistTagKey))
        }
    }

    func isPinnedTag(_ tag: String) -> Bool {
        pinnedTags.contains(Self.favoriteTagKey(tag))
    }

    func isBlacklistedTag(_ tag: String) -> Bool {
        blacklistedTagNames.contains(Self.blacklistTagKey(tag))
    }

    /// Pin / unpin a tag in favorite tags (PostInfoModal.tsx:379-385).
    func togglePinnedTag(_ tag: String) async {
        let key = Self.favoriteTagKey(tag)
        guard !key.isEmpty else { return }
        guard let favoriteTagStore else {
            showToast("Favorite tags are unavailable.")
            return
        }
        let pinned = pinnedTags.contains(key)
        do {
            if pinned {
                try await favoriteTagStore.remove(tag)
                pinnedTags.remove(key)
                showToast("\"\(tag)\" removed from favorites.")
            } else {
                try await favoriteTagStore.add(tag)
                pinnedTags.insert(key)
                showToast("⭐ \"\(tag)\" added to favorite tags!")
            }
        } catch {
            showToast("Could not update favorite tags.")
        }
    }

    /// Add / remove a tag from the blacklist (PostInfoModal.tsx:387-393).
    func toggleBlacklistedTag(_ tag: String) async {
        let key = Self.blacklistTagKey(tag)
        guard !key.isEmpty else { return }
        guard let blacklistStore else {
            showToast("Blacklist is unavailable.")
            return
        }
        let blacklisted = blacklistedTagNames.contains(key)
        do {
            if blacklisted {
                try await blacklistStore.remove(tag)
                blacklistedTagNames.remove(key)
                showToast("\"\(tag)\" removed from blacklist.")
            } else {
                try await blacklistStore.add(tag)
                blacklistedTagNames.insert(key)
                showToast("🚫 \"\(tag)\" added to blacklist!")
            }
        } catch {
            showToast("Could not update the blacklist.")
        }
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    // MARK: Tag key normalization

    /// Mirrors `TagListStore.favorite` normalization: trimmed, whitespace collapsed to
    /// a single space, lowercased (storage.ts:259-280).
    nonisolated static func favoriteTagKey(_ tag: String) -> String {
        tag.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Mirrors `TagListStore.blacklisted` normalization: whitespace collapsed to `_`
    /// and lowercased (storage.ts:316-332).
    nonisolated static func blacklistTagKey(_ tag: String) -> String {
        tag.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_").lowercased()
    }
}
