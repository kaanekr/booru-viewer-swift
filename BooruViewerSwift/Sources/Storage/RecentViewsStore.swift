import Foundation

/// Recently viewed posts persisted as a JSON array, newest first, capped at
/// `PersistenceLimits.recentViews` (500, storage.ts:442, 488, 518).
struct RecentViewsStore: RecentViewsStoring {
    static let fileName = "recent-views"

    private let file: JSONFileStore

    init(file: JSONFileStore) {
        self.file = file
    }

    init(directory: URL) {
        self.init(file: JSONFileStore(directory: directory))
    }

    func list() async throws -> [BooruPost] {
        do {
            return try await file.read(Self.fileName, as: [BooruPost].self) ?? []
        } catch {
            // RN getRecentViews swallows read failures (storage.ts:494-507).
            return []
        }
    }

    /// RN `addRecentView` (storage.ts:509-525):
    /// - a post without an id is ignored,
    /// - re-recording the post that is already first is a no-op (no metadata rewrite),
    /// - otherwise the entry moves to the front and duplicates are dropped by `postKey`,
    /// - the list keeps the newest 500 entries.
    func record(_ post: BooruPost) async throws {
        guard !post.id.isEmpty else { return }
        try await file.update(Self.fileName, defaultValue: [BooruPost]()) { recent in
            if recent.first == post { return }
            let key = postKey(post)
            recent.removeAll { postKey($0) == key }
            recent.insert(post, at: 0)
            let overflow = recent.count - PersistenceLimits.recentViews
            if overflow > 0 {
                recent.removeLast(overflow)
            }
        }
    }
}
