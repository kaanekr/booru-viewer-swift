import Foundation

/// One quick-filter chip and the part of `SearchFilterConfig` it patches.
/// Mirrors the RN `SourceQuickFilter` record (src/utils/sourceQuickFilters.ts:3-8).
struct SourceQuickFilter: Identifiable, Hashable, Sendable {
    /// RN `kind` (sourceQuickFilters.ts:6).
    enum Kind: String, Hashable, Sendable {
        /// Switches sort/time (or the HentaiHaven section).
        case order
        /// Independent on/off filter such as Safe or 50+ Points.
        case toggle
        /// HentaiHaven keyword genre.
        case genre
    }

    /// The `SearchFilterConfig` slice a chip changes (RN `patch`).
    ///
    /// `nil` means "leave this field alone". `setsHentaiHavenSection` separates the
    /// HentaiHaven row that assigns `.latest` from a row that does not touch the section,
    /// which matters because `.latest` is also the implicit default when matching
    /// (sourceQuickFilters.ts:71).
    struct Patch: Hashable, Sendable {
        var sortBy: SortOrder? = nil
        var timeRange: TimeRange? = nil
        var rating: RatingFilter? = nil
        var minScore: Int? = nil
        var cumstService: PlatformFilter? = nil
        var cumstMediaType: MediaTypeFilter? = nil
        var tags: [String]? = nil
        var hentaiHavenSection: HentaiHavenFeedSection? = nil
        var setsHentaiHavenSection = false
        var clearsHentaiHavenSection = false
    }

    /// RN `id`, e.g. `latest`, `score50`, `genre-harem`.
    let id: String
    /// Chip label exactly as RN renders it.
    let label: String
    let kind: Kind
    let patch: Patch
}

/// Which quick-filter list to build (RN `'feed' | 'search'`).
enum SourceQuickFilterContext: Sendable {
    case feed
    case search
}

/// Option building and patching for the Explore feed and search screens.
/// Mirrors `getSourceQuickFilters`, `isQuickFilterActive`, `applyQuickFilter`, and
/// `normalizeFeedQuickFilter` (src/utils/sourceQuickFilters.ts:22-97).
enum SourceQuickFilters {
    // MARK: Shared chips

    private static let latest = order("latest", "Latest", sortBy: .default, timeRange: .all)
    private static let top = order("top", "Top · All time", sortBy: .score, timeRange: .all)
    private static let day = order("day", "Daily Top", sortBy: .score, timeRange: .oneDay)
    private static let week = order("week", "Weekly Top", sortBy: .score, timeRange: .oneWeek)
    private static let month = order("month", "Monthly Top", sortBy: .score, timeRange: .oneMonth)
    private static let relevance = order("default", "Relevance", sortBy: .default)
    private static let discover = order("default", "Discover", sortBy: .default)
    private static let rated = order("rated", "Top Rated", sortBy: .rating)

    private static let safe = SourceQuickFilter(
        id: "safe",
        label: "Safe",
        kind: .toggle,
        patch: SourceQuickFilter.Patch(rating: .safe)
    )
    private static let score = SourceQuickFilter(
        id: "score50",
        label: "50+ Points",
        kind: .toggle,
        patch: SourceQuickFilter.Patch(minScore: 50)
    )
    private static let videos = SourceQuickFilter(
        id: "videos",
        label: "Videos",
        kind: .toggle,
        patch: SourceQuickFilter.Patch(cumstMediaType: .videos)
    )
    private static let onlyfans = SourceQuickFilter(
        id: "onlyfans",
        label: "OnlyFans",
        kind: .toggle,
        patch: SourceQuickFilter.Patch(cumstService: .onlyfans)
    )
    private static let fansly = SourceQuickFilter(
        id: "fansly",
        label: "Fansly",
        kind: .toggle,
        patch: SourceQuickFilter.Patch(cumstService: .fansly)
    )

    /// Cum.st chips that force the keywordless listing endpoint (:84-90).
    private static let cumstListIDs: Set<String> = ["videos", "onlyfans", "fansly"]
    /// Timed tops that reset the incompatible Cum.st sides (:88-90).
    private static let timedTopIDs: Set<String> = ["day", "week", "month"]

    // MARK: Option building

    /// Only controls the adapter actually sends (sourceQuickFilters.ts:22-65).
    /// Feed and keyword search differ per source, so the caller passes the context.
    static func options(
        for source: SourceID,
        context: SourceQuickFilterContext = .feed,
        hasQuery: Bool = false
    ) -> [SourceQuickFilter] {
        let search = context == .search

        switch source {
        case .danbooru, .yandere:
            return [latest, top, day, week, month] + (search ? [safe, score] : [])
        case .gelbooru, .rule34, .realbooru:
            // Explore exposes the same time-bounded tops as search: `sort:score:desc`
            // is always sent, and the Gelbooru/Rule34 id-bound walk narrows the range
            // (Realbooru has no date window, so a timed top degrades to the score order).
            return [latest, top, day, week, month] + (search ? [safe, score] : [])
        case .redgifs:
            return [latest, top, day, week, month]
        case .cumst:
            return [latest, top, day, week, month]
                + (search ? [videos, onlyfans, fansly] : [])
        case .xvideos:
            return search && hasQuery
                ? [relevance, latest, top, day, week, month, rated]
                : [latest, top, day, week, month]
        case .xhamster:
            return search && hasQuery
                ? [relevance, latest, top, day, week, month, rated]
                : [latest, top, day, week, month]
        case .pornhub:
            return search && hasQuery
                ? [relevance, latest, top, day, week, month, rated]
                : [latest, top, day, week, month]
        case .sexcom:
            return []
        case .nhentai:
            return [latest, day, week, month, top]
        case .hentaihaven:
            return hentaiHavenSections + (search ? hentaiHavenGenres : [])
        }
    }

    private static func order(
        _ id: String,
        _ label: String,
        sortBy: SortOrder,
        timeRange: TimeRange = .all
    ) -> SourceQuickFilter {
        SourceQuickFilter(
            id: id,
            label: label,
            kind: .order,
            patch: SourceQuickFilter.Patch(sortBy: sortBy, timeRange: timeRange)
        )
    }

    /// HentaiHaven Explore sections (`HentaiHavenFeedSection` order matches :56).
    private static var hentaiHavenSections: [SourceQuickFilter] {
        HentaiHavenFeedSection.allCases.map { section in
            SourceQuickFilter(
                id: section.rawValue,
                label: hentaiHavenSectionLabel(section),
                kind: .order,
                patch: SourceQuickFilter.Patch(
                    sortBy: .default,
                    timeRange: .all,
                    hentaiHavenSection: section,
                    setsHentaiHavenSection: true
                )
            )
        }
    }

    private static let hentaiHavenSectionTitles: [HentaiHavenFeedSection: String] = [
        .latest: "Latest",
        .trending: "Monthly Trends",
        .episodes: "Latest Episodes",
    ]

    /// RN keeps three custom labels and capitalizes the rest (:57).
    private static func hentaiHavenSectionLabel(_ section: HentaiHavenFeedSection) -> String {
        hentaiHavenSectionTitles[section] ?? section.rawValue.capitalized
    }

    /// Keyword genres only exist in search, and they clear the section (:60).
    private static let genreSlugs = ["harem", "anal", "milf", "bdsm"]

    private static var hentaiHavenGenres: [SourceQuickFilter] {
        genreSlugs.map { genre in
            SourceQuickFilter(
                id: "genre-\(genre)",
                label: genre.capitalized,
                kind: .genre,
                patch: SourceQuickFilter.Patch(
                    sortBy: .default,
                    timeRange: .all,
                    tags: [genre],
                    clearsHentaiHavenSection: true
                )
            )
        }
    }

    // MARK: Active / apply

    /// RN `isQuickFilterActive` (:67-74): every patched field must match the filter.
    static func isActive(_ option: SourceQuickFilter, in filter: SearchFilterConfig) -> Bool {
        switch option.id {
        case "latest":
            if option.patch.setsHentaiHavenSection {
                return (filter.hentaiHavenSection ?? .latest) == .latest
                    && filter.sortBy == .default
                    && filter.timeRange == .all
            }
            return filter.sortBy == .default && filter.timeRange == .all
        case "top":
            return filter.sortBy == .score && filter.timeRange == .all
        case "day":
            return filter.timeRange == .oneDay
        case "week":
            return filter.timeRange == .oneWeek
        case "month":
            return filter.timeRange == .oneMonth
        default:
            break
        }

        let patch = option.patch
        if let value = patch.sortBy, filter.sortBy != value { return false }
        if let value = patch.timeRange, filter.timeRange != value { return false }
        if let value = patch.rating, filter.rating != value { return false }
        if let value = patch.minScore, filter.minScore != value { return false }
        if let value = patch.cumstService, (filter.cumstService ?? .all) != value { return false }
        if let value = patch.cumstMediaType, (filter.cumstMediaType ?? .all) != value { return false }
        if let value = patch.tags, filter.tags != value { return false }
        // A missing HentaiHaven section reads as `latest` (:71).
        if patch.setsHentaiHavenSection,
           (filter.hentaiHavenSection ?? .latest) != (patch.hentaiHavenSection ?? .latest) {
            return false
        }
        if patch.clearsHentaiHavenSection, filter.hentaiHavenSection != nil { return false }
        return true
    }

    /// RN `applyQuickFilter` (:76-92).
    static func apply(
        _ option: SourceQuickFilter,
        to filter: SearchFilterConfig,
        toggle: Bool = true
    ) -> SearchFilterConfig {
        var next = filter
        let patch = option.patch

        switch option.id {
        case "latest":
            next.sortBy = .default
            next.timeRange = .all
        case "top":
            next.sortBy = .score
            next.timeRange = .all
        case "day":
            next.sortBy = .score
            next.timeRange = .oneDay
        case "week":
            next.sortBy = .score
            next.timeRange = .oneWeek
        case "month":
            next.sortBy = .score
            next.timeRange = .oneMonth
        default:
            if let value = patch.sortBy { next.sortBy = value }
            if let value = patch.timeRange { next.timeRange = value }
        }

        if let value = patch.rating { next.rating = value }
        if let value = patch.minScore { next.minScore = value }
        if let value = patch.cumstService { next.cumstService = value }
        if let value = patch.cumstMediaType { next.cumstMediaType = value }
        if let value = patch.tags { next.tags = value }
        if patch.setsHentaiHavenSection { next.hentaiHavenSection = patch.hentaiHavenSection }
        if patch.clearsHentaiHavenSection { next.hentaiHavenSection = nil }
        next.jumpToPage = 1

        // Tapping an active toggle turns it back off (:78-83).
        if option.kind == .toggle, toggle, isActive(option, in: filter) {
            switch option.id {
            case "safe":
                next.rating = .all
            case "score50":
                next.minScore = nil
            case "videos":
                next.cumstMediaType = .all
            case "onlyfans", "fansly":
                next.cumstService = .all
            default:
                break
            }
        }

        // Cum.st's popular endpoint ignores service/type filters, and the timed tops
        // ignore them too: reset the incompatible side instead of lighting a no-op
        // button (:84-90).
        if cumstListIDs.contains(option.id) {
            next.sortBy = .id
            next.timeRange = .all
            next.leaderboardDate = nil
        } else if timedTopIDs.contains(option.id) || option.id == "top" {
            next.cumstMediaType = .all
            next.cumstService = .all
        }
        return next
    }

    // MARK: Feed order

    /// RN `normalizeFeedQuickFilter` (:94-97): a saved order from another source must
    /// not leak into this one; it is snapped to the first chip this source exposes.
    static func normalizedFeedOrder(for source: SourceID, saved: FeedOrder?) -> FeedOrder {
        let feedOptions = options(for: source, context: .feed)

        var current = SearchFilterConfig()
        if let saved {
            current.sortBy = saved.sortBy
            current.timeRange = saved.timeRange
            current.hentaiHavenSection = saved.hentaiHavenSection
        }

        guard let patch = feedOptions.first(where: { isActive($0, in: current) })?.patch
            ?? feedOptions.first?.patch else {
            return FeedOrder(sortBy: .default, timeRange: .all)
        }
        return FeedOrder(
            sortBy: patch.sortBy ?? .default,
            timeRange: patch.timeRange ?? .all,
            hentaiHavenSection: patch.setsHentaiHavenSection ? patch.hentaiHavenSection : nil
        )
    }
}
