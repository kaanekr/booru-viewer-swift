import Foundation

/// Favorites persisted as a JSON array of posts.
///
/// Dedupe uses `postKey` only, exactly like RN `uniquePosts` (storage.ts:72-80) and the toggle paths
/// (storage.ts:157-174); new favorites go to the front. RN additionally dedupes by `mediaKey` during
/// backup import (backupService.ts:308-316), which is a separate concern from this runtime store.
struct FavoritesStore: FavoritesStoring {
    static let fileName = "favorites"

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
            // RN getFavorites swallows read failures and reports an empty list (storage.ts:147-155).
            return []
        }
    }

    /// Prepends unless the post is already favorited (storage.ts:171).
    func add(_ post: BooruPost) async throws {
        try await file.update(Self.fileName, defaultValue: [BooruPost]()) { posts in
            let key = postKey(post)
            guard !posts.contains(where: { postKey($0) == key }) else { return }
            posts.insert(post, at: 0)
        }
    }

    /// Removes every entry with the source-qualified key of `id` + `sourceID`.
    func remove(id: String, sourceID: SourceID) async throws {
        let key = postKey(identityPost(id: id, sourceID: sourceID))
        try await file.update(Self.fileName, defaultValue: [BooruPost]()) { posts in
            posts.removeAll { postKey($0) == key }
        }
    }

    func contains(_ post: BooruPost) async throws -> Bool {
        let posts = (try? await list()) ?? []
        let key = postKey(post)
        return posts.contains { postKey($0) == key }
    }

    /// `postKey` needs a whole `BooruPost`; only `id` and `sourceID` contribute to the key
    /// (PostIdentity.swift:8-19), so the remaining fields are placeholders and are never persisted.
    private func identityPost(id: String, sourceID: SourceID) -> BooruPost {
        BooruPost(
            id: id,
            sourceID: sourceID,
            sourceName: "",
            title: nil,
            previewURL: nil,
            previewFallbackURL: nil,
            previewVideoURL: nil,
            previewThumbURL: nil,
            previewThumbs: nil,
            sampleURL: nil,
            originalURL: nil,
            width: 0,
            height: 0,
            aspectRatio: 1,
            rating: .general,
            score: 0,
            favCount: 0,
            tags: BooruTagGroups(),
            allTags: [],
            sourceLink: nil,
            fileExt: nil,
            fileSize: nil,
            createdAt: "",
            niches: nil,
            isPremium: nil,
            pageCount: nil,
            mediaId: nil
        )
    }
}
