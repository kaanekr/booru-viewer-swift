import SwiftUI

/// Sheet that edits the structured search options. Mirrors RN `SearchFilterModal.tsx`:
/// sort, time range, rating, minimum score, user, jump-to-page, leaderboard date,
/// Cum.st service/media type, HentaiHaven section, plus the tag chips and a reset action.
///
/// The sheet edits a local draft, so closing it without Apply keeps the current filter.
struct SearchFilterSheetView: View {
    @Binding private var config: SearchFilterConfig
    private let sourceID: SourceID
    private let onApply: (SearchFilterConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: SearchFilterConfig
    @State private var tagInput = ""

    init(
        config: Binding<SearchFilterConfig>,
        sourceID: SourceID = .gelbooru,
        onApply: @escaping (SearchFilterConfig) -> Void = { _ in }
    ) {
        _config = config
        self.sourceID = sourceID
        self.onApply = onApply
        _draft = State(initialValue: config.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                tagsSection
                sortSection
                if showsTimeRange {
                    timeRangeSection
                }
                ratingSection
                scoreSection
                userSection
                pageSection
                if showsLeaderboardDate {
                    leaderboardSection
                }
                if sourceID == .cumst {
                    cumstSection
                }
                if sourceID == .hentaihaven {
                    hentaiHavenSection
                }
                automationSection
                resetSection
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(AppTheme.primary)
    }

    // MARK: Sections

    private var tagsSection: some View {
        Section("Tags") {
            if !draft.tags.isEmpty {
                TagChipRow(tags: draft.tags) { tag in
                    draft.tags.removeAll { $0 == tag }
                }
            }
            HStack(spacing: 8) {
                TextField(draft.tags.isEmpty ? "Add tag (e.g.: 1girl)..." : "Add more...", text: $tagInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(addTagsFromInput)
                if !tagInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add", action: addTagsFromInput)
                        .font(.footnote.weight(.semibold))
                }
            }
        }
    }

    private var sortSection: some View {
        Section("Sort") {
            Picker("Sort by", selection: $draft.sortBy) {
                ForEach(sortOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var timeRangeSection: some View {
        Section("Time Range") {
            Picker("Posted", selection: $draft.timeRange) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    Text(Self.timeRangeLabel(range)).tag(range)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var ratingSection: some View {
        Section("Rating") {
            Picker("Rating", selection: $draft.rating) {
                ForEach(RatingFilter.allCases, id: \.self) { rating in
                    Text(Self.ratingLabel(rating)).tag(rating)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var scoreSection: some View {
        Section("Minimum Score") {
            Picker("Score", selection: $draft.minScore) {
                Text("Any").tag(Int?.none)
                ForEach(scoreOptions, id: \.self) { score in
                    Text("\(score)+").tag(Int?.some(score))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var userSection: some View {
        Section("User") {
            TextField("Artist or uploader", text: userBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var pageSection: some View {
        Section("Jump to Page") {
            Stepper(value: pageBinding, in: 1...9999) {
                Text(draft.jumpToPage > 1 ? "Page \(draft.jumpToPage)" : "Start at page 1")
            }
            if draft.jumpToPage > 1 {
                Button("Reset to page 1") { draft.jumpToPage = 1 }
                    .font(.footnote)
            }
        }
    }

    private var leaderboardSection: some View {
        Section("Leaderboard Date") {
            TextField("YYYY-MM-DD", text: leaderboardDateBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if draft.leaderboardDate?.isEmpty == false {
                Button("Clear date") { draft.leaderboardDate = nil }
                    .font(.footnote)
            }
        }
    }

    private var cumstSection: some View {
        Section("Cum.st") {
            Picker("Service", selection: $draft.cumstService) {
                ForEach(PlatformFilter.allCases, id: \.self) { service in
                    Text(Self.serviceLabel(service)).tag(PlatformFilter?.some(service))
                }
            }
            .pickerStyle(.menu)

            Picker("Media", selection: $draft.cumstMediaType) {
                ForEach(MediaTypeFilter.allCases, id: \.self) { media in
                    Text(Self.mediaTypeLabel(media)).tag(MediaTypeFilter?.some(media))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var hentaiHavenSection: some View {
        Section("HentaiHaven") {
            Picker("Section", selection: $draft.hentaiHavenSection) {
                Text("Automatic").tag(HentaiHavenFeedSection?.none)
                ForEach(HentaiHavenFeedSection.allCases, id: \.self) { section in
                    Text(Self.hentaiHavenLabel(section)).tag(HentaiHavenFeedSection?.some(section))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var automationSection: some View {
        Section {
            Toggle("Server tag autocomplete", isOn: $draft.autocompleteFromServer)
            Toggle("Include blacklisted posts", isOn: $draft.includeBlacklisted)
        } footer: {
            Text("Blacklisted tags hide results until you reveal them.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset", role: .destructive, action: reset)
        }
    }

    // MARK: Actions

    /// Applies the draft plus any text left in the tag field (SearchFilterModal.tsx:310-331).
    private func apply() {
        addTagsFromInput()
        config = draft
        onApply(draft)
        dismiss()
    }

    /// RN keeps `autocompleteFromServer` across a reset (SearchFilterModal.tsx:289-298); the tag list
    /// is kept too so the sheet never desyncs from the search field.
    private func reset() {
        let tags = draft.tags
        let autocomplete = draft.autocompleteFromServer
        draft = SearchFilterConfig(autocompleteFromServer: autocomplete)
        draft.tags = tags
        tagInput = ""
    }

    private func addTagsFromInput() {
        // Space- or comma-separated; a quoted group stays whole (SearchFilterModal.tsx:237-254).
        let parts = SearchViewModel.parseTags(tagInput.replacingOccurrences(of: ",", with: " "))
        for tag in parts where !draft.tags.contains(tag) {
            draft.tags.append(tag)
        }
        tagInput = ""
    }

    // MARK: Bindings

    private var userBinding: Binding<String> {
        Binding(
            get: { draft.user ?? "" },
            set: { draft.user = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private var leaderboardDateBinding: Binding<String> {
        Binding(
            get: { draft.leaderboardDate ?? "" },
            set: { draft.leaderboardDate = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private var pageBinding: Binding<Int> {
        Binding(
            get: { max(1, draft.jumpToPage) },
            set: { draft.jumpToPage = min(max($0, 1), 9999) }
        )
    }

    // MARK: Source-specific options

    private var showsTimeRange: Bool {
        switch sourceID {
        case .cumst, .hentaihaven, .nhentai, .sexcom:
            return false
        default:
            return true
        }
    }

    /// The leaderboard anchor only applies to the booru engines with a date filter.
    private var showsLeaderboardDate: Bool {
        switch sourceID {
        case .gelbooru, .rule34, .danbooru, .realbooru, .yandere:
            return true
        default:
            return false
        }
    }

    private struct SortOptionItem {
        var label: String
        var value: SortOrder
    }

    /// Labels mirror the per-source lists in SearchFilterModal.tsx:48-107.
    private var sortOptions: [SortOptionItem] {
        switch sourceID {
        case .redgifs:
            return [
                SortOptionItem(label: "---", value: .default),
                SortOptionItem(label: "Trending", value: .score),
                SortOptionItem(label: "Latest", value: .id)
            ]
        case .xvideos:
            return [
                SortOptionItem(label: "---", value: .default),
                SortOptionItem(label: "Newest", value: .id),
                SortOptionItem(label: "Views", value: .score),
                SortOptionItem(label: "Rating Ratio", value: .rating),
                SortOptionItem(label: "Duration", value: .height)
            ]
        case .xhamster:
            return [
                SortOptionItem(label: "---", value: .default),
                SortOptionItem(label: "Newest", value: .id),
                SortOptionItem(label: "Views", value: .score),
                SortOptionItem(label: "Top Rated", value: .rating),
                SortOptionItem(label: "Duration", value: .height)
            ]
        case .pornhub:
            return [
                SortOptionItem(label: "---", value: .default),
                SortOptionItem(label: "Newest", value: .id),
                SortOptionItem(label: "Views", value: .score),
                SortOptionItem(label: "Rating Ratio", value: .rating)
            ]
        case .sexcom:
            return [SortOptionItem(label: "---", value: .default)]
        case .hentaihaven:
            return [
                SortOptionItem(label: "Newest", value: .default),
                SortOptionItem(label: "Monthly Trends", value: .score)
            ]
        case .nhentai:
            return [
                SortOptionItem(label: "---", value: .default),
                SortOptionItem(label: "Newest", value: .id),
                SortOptionItem(label: "Popular", value: .score)
            ]
        case .cumst:
            return [
                SortOptionItem(label: "Score (Popularity)", value: .score),
                SortOptionItem(label: "Id (Newest)", value: .id),
                SortOptionItem(label: "Videos", value: .width),
                SortOptionItem(label: "Multiple Media", value: .height)
            ]
        default:
            return [
                SortOptionItem(label: "---", value: .default),
                SortOptionItem(label: "Id", value: .id),
                SortOptionItem(label: "Score", value: .score),
                SortOptionItem(label: "Rating", value: .rating),
                SortOptionItem(label: "User", value: .user),
                SortOptionItem(label: "Height", value: .height),
                SortOptionItem(label: "Width", value: .width)
            ]
        }
    }

    /// nhentai scores favourites on a much larger scale (SearchFilterModal.tsx:146-153).
    private var scoreOptions: [Int] {
        sourceID == .nhentai ? [100, 500, 1000, 5000, 10000] : [10, 50, 100, 500]
    }

    // MARK: Labels

    private static func timeRangeLabel(_ range: TimeRange) -> String {
        switch range {
        case .all: return "All Time"
        case .oneDay: return "Last 24 Hours / Daily Leader"
        case .oneWeek: return "This Week / Weekly Leader"
        case .oneMonth: return "This Month / Monthly Leader"
        case .oneYear: return "This Year"
        }
    }

    private static func ratingLabel(_ rating: RatingFilter) -> String {
        switch rating {
        case .all: return "All"
        case .safe: return "Safe"
        case .questionable: return "Questionable"
        case .explicit: return "Explicit (18+)"
        }
    }

    private static func serviceLabel(_ service: PlatformFilter) -> String {
        switch service {
        case .all: return "All"
        case .onlyfans: return "OnlyFans"
        case .fansly: return "Fansly"
        }
    }

    private static func mediaTypeLabel(_ media: MediaTypeFilter) -> String {
        switch media {
        case .all: return "All"
        case .videos: return "Videos Only"
        case .photos: return "Photos Only"
        case .audio: return "Audio"
        }
    }

    private static func hentaiHavenLabel(_ section: HentaiHavenFeedSection) -> String {
        switch section {
        case .latest: return "Latest"
        case .trending: return "Trending"
        case .episodes: return "Episodes"
        case .yuri: return "Yuri"
        case .ecchi: return "Ecchi"
        case .incest: return "Incest"
        case .tentacle: return "Tentacle"
        case .uncensored: return "Uncensored"
        }
    }
}

/// Draft tag chips in a horizontally scrolling row inside the form.
private struct TagChipRow: View {
    private let tags: [String]
    private let onRemove: (String) -> Void

    init(tags: [String], onRemove: @escaping (String) -> Void) {
        self.tags = tags
        self.onRemove = onRemove
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    TagChipView(text: tag, isSelected: true, onTap: { onRemove(tag) })
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }
}
