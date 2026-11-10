import SwiftUI
import UIKit

/// Async image with a static-cover fallback chain, loading through
/// `MediaImageLoader` so the request carries the media headers and the proxy
/// routing that `AsyncImage` cannot express.
///
/// RN keeps up to four cover attempts per card (PostCard.tsx:202-236): the primary
/// cover, the poster/thumbnail fallbacks, then a proxy leg. The proxy leg is now a
/// transport concern (`MediaImageLoader`), so this view walks the URL chain and
/// advances only when a load really fails, keeping the card fill underneath so a
/// loading card never flashes black.
///
/// Two loaders stack on a card: the base cover and the timed preview frame drawn
/// above it. The frame layer therefore opts out of the opaque fill
/// (`LoadingPlaceholder.transparent`) and keeps whatever it already decoded
/// (`keepsPreviousImageWhileLoading`), so a frame that is still loading or that
/// fails outright can never paint over the cover it sits on.
struct AsyncMediaImage: View {
    /// What this layer shows while it has no decoded image.
    enum LoadingPlaceholder: Equatable, Sendable {
        /// Opaque card fill, the default for a card's base cover.
        case cardFill
        /// Nothing at all, so a layer underneath stays visible. Preview frames use
        /// this: they are an overlay, not the card background.
        case transparent
    }

    /// Loading behaviour for a layer stacked on top of a card's base cover, e.g. the
    /// timed preview frame. Single-sourced so the overlay wiring stays testable and
    /// cannot drift back to the opaque fill that used to mask a loaded cover.
    struct OverlayConfiguration: Equatable, Sendable {
        let placeholder: LoadingPlaceholder
        let keepsPreviousImageWhileLoading: Bool
    }

    static let overlayConfiguration = OverlayConfiguration(
        placeholder: .transparent,
        keepsPreviousImageWhileLoading: true
    )

    private let urls: [URL]
    private let contentMode: ContentMode
    private let placeholderStyle: LoadingPlaceholder
    private let keepsPreviousImageWhileLoading: Bool
    private let onImageLoaded: ((UIImage) -> Void)?

    /// Decoded image for the current chain; `nil` while loading or failed.
    @State private var image: UIImage?

    /// - Parameters:
    ///   - url: primary URL.
    ///   - fallbackURLs: tried in order after `url` fails.
    ///   - contentMode: `.fill` for covers, `.fit` for detail images.
    ///   - placeholder: fill drawn while nothing has decoded.
    ///   - keepsPreviousImageWhileLoading: when true, retargeting this view keeps
    ///     the last decoded image on screen until a new one decodes (or the chain
    ///     fails), instead of dropping back to the placeholder.
    ///   - onImageLoaded: invoked whenever an image is resolved from cache or network.
    init(
        url: URL?,
        fallbackURLs: [URL] = [],
        contentMode: ContentMode = .fill,
        placeholder: LoadingPlaceholder = .cardFill,
        keepsPreviousImageWhileLoading: Bool = false,
        onImageLoaded: ((UIImage) -> Void)? = nil
    ) {
        var chain: [URL] = []
        for candidate in ([url].compactMap { $0 } + fallbackURLs) where !chain.contains(candidate) {
            chain.append(candidate)
        }
        urls = chain
        self.contentMode = contentMode
        placeholderStyle = placeholder
        self.keepsPreviousImageWhileLoading = keepsPreviousImageWhileLoading
        self.onImageLoaded = onImageLoaded
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholderView
            }
        }
        .task(id: urls) { await load() }
    }

    /// Same fill as the card body, so a loading card never flashes a light panel.
    /// A layered overlay instead draws nothing, leaving the layer below intact.
    @ViewBuilder
    private var placeholderView: some View {
        switch placeholderStyle {
        case .cardFill: AppTheme.card
        case .transparent: Color.clear
        }
    }

    /// Image a finished load attempt leaves on screen. A failed or still-loading
    /// attempt never erases an image that already decoded when the layer retains it.
    static func resolvedImage(
        previous: UIImage?,
        resolved: UIImage?,
        keepsPreviousImage: Bool
    ) -> UIImage? {
        guard keepsPreviousImage else { return resolved }
        return resolved ?? previous
    }

    /// Walks the chain until one URL decodes; a cached image is applied without
    /// a visible placeholder frame.
    private func load() async {
        guard !urls.isEmpty else {
            image = Self.resolvedImage(
                previous: image,
                resolved: nil,
                keepsPreviousImage: keepsPreviousImageWhileLoading
            )
            return
        }
        if !keepsPreviousImageWhileLoading {
            image = nil
        }
        for url in urls {
            if Task.isCancelled { return }
            if let cached = await MediaImageLoader.shared.cachedImage(for: url) {
                if Task.isCancelled { return }
                image = cached
                onImageLoaded?(cached)
                return
            }
            do {
                let loaded = try await MediaImageLoader.shared.image(for: url)
                if Task.isCancelled { return }
                withAnimation(.easeIn(duration: 0.15)) {
                    image = loaded
                }
                onImageLoaded?(loaded)
                return
            } catch is CancellationError {
                // The view was retargeted (new post/cover/frame). A stale result must
                // never land on the new identity.
                return
            } catch {
                // Real failure only: the loader already retried the other route leg.
                continue
            }
        }
        // Every candidate failed: an overlay keeps its last good frame (the cover
        // below stays visible when there is none), a base cover keeps its fill.
        image = Self.resolvedImage(
            previous: image,
            resolved: nil,
            keepsPreviousImage: keepsPreviousImageWhileLoading
        )
    }
}
