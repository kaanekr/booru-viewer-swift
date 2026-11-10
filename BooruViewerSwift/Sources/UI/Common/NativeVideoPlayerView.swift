import AVFoundation
import AVKit
import Foundation
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Pure state machine governing `AVPlayer` ownership, finite-clip looping,
/// native play/pause intent, active-page gating, item-identity binding, async KVO
/// pause reconciliation, and bounded route fallback retries.
///
/// Kept pure and UIKit-free so callback orderings (natural-EOF `.paused` before or
/// after `didPlayToEndTime`, user pause mid-seek, async KVO after programmatic pause,
/// stale HH episode callbacks, and bounded fallback retries) are directly unit-tested.
struct NativePlaybackLifecycle: Equatable, Sendable {
    enum TimeControlState: Equatable, Sendable {
        case paused
        case waitingToPlay
        case playing
    }

    enum SeekReason: Equatable, Sendable {
        case loopAtEnd
        case reactivatedAtEnd
    }

    enum LoopStage: Equatable, Sendable {
        case idle
        case seekingToZero(generation: Int, reason: SeekReason)
    }

    enum Action: Equatable, Sendable {
        case none
        case play
        case pause
        case seekToZeroAndResume(generation: Int)
    }

    /// Tolerance used when differentiating an automatic EOF pause from a mid-clip
    /// user pause when `.paused` KVO arrives ahead of `didPlayToEndTime`.
    static let naturalEOFPauseTolerance: Double = 0.05
    /// Tolerance used when resuming playback on return to a clip already near EOF.
    static let reactivationEndTolerance: Double = 0.15

    private(set) var currentURL: URL?
    private(set) var currentPlayerID: ObjectIdentifier?
    private(set) var currentItemID: ObjectIdentifier?
    private(set) var isActive = false
    private(set) var isDisposed = false
    private(set) var isUserPaused = false
    private(set) var pausedAtNaturalEOF = false
    private(set) var ignoredProgrammaticPauses = 0
    private(set) var timeControlState: TimeControlState = .paused
    private(set) var routeAttemptCount = 0
    private(set) var routeAttemptIndex = 0
    private(set) var loopSeekGeneration = 0
    private(set) var loopStage: LoopStage = .idle

    var pendingLoopSeekGeneration: Int? {
        if case let .seekingToZero(generation, _) = loopStage {
            return generation
        }
        return nil
    }

    static func isFinitePlayableDuration(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds > 0
    }

    static func hasReachedEnd(
        currentTime: Double,
        duration: Double,
        tolerance: Double = reactivationEndTolerance
    ) -> Bool {
        isFinitePlayableDuration(duration)
            && currentTime.isFinite
            && currentTime >= max(0, duration - tolerance)
    }

    mutating func configure(
        url: URL,
        playerID: ObjectIdentifier,
        itemID: ObjectIdentifier,
        routeAttemptCount: Int,
        isActive: Bool
    ) -> Action {
        isDisposed = false
        currentURL = url
        currentPlayerID = playerID
        currentItemID = itemID
        self.routeAttemptCount = max(routeAttemptCount, 1)
        self.routeAttemptIndex = 0
        self.isActive = isActive
        isUserPaused = false
        pausedAtNaturalEOF = false
        ignoredProgrammaticPauses = 0
        timeControlState = .paused
        invalidatePendingSeek()
        return isActive ? .play : .none
    }

    mutating func replaceURL(
        _ url: URL,
        itemID: ObjectIdentifier,
        routeAttemptCount: Int,
        isActive: Bool
    ) -> Action {
        guard !isDisposed else { return .none }
        currentURL = url
        currentItemID = itemID
        self.routeAttemptCount = max(routeAttemptCount, 1)
        self.routeAttemptIndex = 0
        self.isActive = isActive
        isUserPaused = false
        pausedAtNaturalEOF = false
        invalidatePendingSeek()
        if isActive {
            ignoredProgrammaticPauses = 0
            return .play
        }
        return .pause
    }

    mutating func setActive(
        _ active: Bool,
        currentTime: Double,
        duration: Double
    ) -> Action {
        guard !isDisposed, isActive != active else { return .none }
        isActive = active
        invalidatePendingSeek()

        if !active {
            pausedAtNaturalEOF = false
            return .pause
        }

        guard !isUserPaused else { return .none }

        if Self.hasReachedEnd(
            currentTime: currentTime,
            duration: duration,
            tolerance: Self.reactivationEndTolerance
        ) {
            pausedAtNaturalEOF = false
            return beginSeekToZero(reason: .reactivatedAtEnd)
        }
        pausedAtNaturalEOF = false
        return .play
    }

    /// Records that the coordinator is about to issue a programmatic `player.pause()`
    /// while `player.timeControlStatus` is non-paused, so the resulting async `.paused`
    /// KVO notification is not misclassified as a user pause (even across fast
    /// offscreen/onscreen round-trips).
    mutating func willIssueProgrammaticPause() {
        guard !isDisposed else { return }
        ignoredProgrammaticPauses += 1
    }

    mutating func observeTimeControlState(
        _ state: TimeControlState,
        currentTime: Double = 0,
        duration: Double = .nan,
        itemFailed: Bool = false
    ) {
        guard !isDisposed else { return }
        let previousState = timeControlState
        timeControlState = state

        switch state {
        case .playing, .waitingToPlay:
            pausedAtNaturalEOF = false
            if isActive {
                isUserPaused = false
                ignoredProgrammaticPauses = 0
            }

        case .paused:
            pausedAtNaturalEOF = false
            if ignoredProgrammaticPauses > 0 {
                ignoredProgrammaticPauses -= 1
                return
            }
            if itemFailed {
                return
            }
            guard isActive else { return }

            // If we are NOT mid-seek, were actively playing/waiting right before, and
            // the current finite position has reached natural EOF, AVPlayer paused due
            // to reaching end-of-item ahead of `didPlayToEndTime`. Mark `pausedAtNaturalEOF`
            // without latching `isUserPaused` so the upcoming end notification can loop.
            let isNaturalEOFPause = loopStage == .idle
                && !isUserPaused
                && previousState != .paused
                && Self.hasReachedEnd(
                    currentTime: currentTime,
                    duration: duration,
                    tolerance: Self.naturalEOFPauseTolerance
                )

            if isNaturalEOFPause {
                pausedAtNaturalEOF = true
                return
            }

            // Any other onscreen pause (mid-clip, already paused, or mid-seek) is user/system pause.
            isUserPaused = true
            invalidatePendingSeek()
        }
    }

    mutating func handleDidPlayToEnd(
        playerID: ObjectIdentifier,
        itemID: ObjectIdentifier,
        duration: Double,
        liveTimeControlState: TimeControlState
    ) -> Action {
        let wasNaturalEOF = pausedAtNaturalEOF
        pausedAtNaturalEOF = false

        guard !isDisposed,
              isActive,
              currentPlayerID == playerID,
              currentItemID == itemID,
              !isUserPaused,
              (liveTimeControlState != .paused || wasNaturalEOF),
              Self.isFinitePlayableDuration(duration),
              loopStage == .idle else {
            return .none
        }
        return beginSeekToZero(reason: .loopAtEnd)
    }

    mutating func handleLoopSeekCompleted(
        generation: Int,
        finished: Bool,
        playerID: ObjectIdentifier,
        itemID: ObjectIdentifier
    ) -> Action {
        guard case let .seekingToZero(pendingGen, _) = loopStage,
              pendingGen == generation else {
            return .none
        }
        loopStage = .idle

        guard finished,
              !isDisposed,
              isActive,
              currentPlayerID == playerID,
              currentItemID == itemID,
              !isUserPaused else {
            return .none
        }
        return .play
    }

    mutating func cancelPendingLoopSeek() {
        invalidatePendingSeek()
    }

    mutating func nextRetryAttemptIndex(
        playerID: ObjectIdentifier,
        itemID: ObjectIdentifier
    ) -> Int? {
        guard !isDisposed,
              currentPlayerID == playerID,
              currentItemID == itemID else {
            return nil
        }
        let next = routeAttemptIndex + 1
        guard next < routeAttemptCount else { return nil }
        routeAttemptIndex = next
        pausedAtNaturalEOF = false
        invalidatePendingSeek()
        return next
    }

    mutating func bindRetryItem(itemID: ObjectIdentifier) -> Action {
        guard !isDisposed else { return .none }
        currentItemID = itemID
        pausedAtNaturalEOF = false
        invalidatePendingSeek()
        return (isActive && !isUserPaused) ? .play : .none
    }

    mutating func dispose() {
        isDisposed = true
        isActive = false
        pausedAtNaturalEOF = false
        ignoredProgrammaticPauses = 0
        invalidatePendingSeek()
        currentPlayerID = nil
        currentItemID = nil
    }

    private mutating func beginSeekToZero(reason: SeekReason) -> Action {
        loopSeekGeneration &+= 1
        loopStage = .seekingToZero(generation: loopSeekGeneration, reason: reason)
        return .seekToZeroAndResume(generation: loopSeekGeneration)
    }

    private mutating func invalidatePendingSeek() {
        loopSeekGeneration &+= 1
        loopStage = .idle
    }
}

/// Genuine native `AVPlayerViewController` video host wrapped inside a dedicated
/// container controller (`NativePlayerContainerViewController`) that keeps
/// `showsPlaybackControls = true` set once at creation, insets the player strictly
/// inside its app-chrome safe bounds, arbitrates control/scrubber touches with ONLY
/// the nearest enclosing post-pager `UIScrollView`, and drives playback through
/// `NativePlaybackLifecycle`.
struct NativeVideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    var isActive: Bool
    var contentInsets: UIEdgeInsets = .zero

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> NativePlayerContainerViewController {
        let playerViewController = AVPlayerViewController()
        // Set once at creation per Apple AVKit guidance: toggling while onscreen
        // tears down and rebuilds the native transport hierarchy.
        playerViewController.showsPlaybackControls = true
        playerViewController.videoGravity = .resizeAspect
        playerViewController.view.backgroundColor = .black
        playerViewController.delegate = context.coordinator

        let container = NativePlayerContainerViewController(
            playerViewController: playerViewController,
            contentInsets: contentInsets
        )
        context.coordinator.configure(container: container, url: url, isActive: isActive)
        return container
    }

    func updateUIViewController(_ uiViewController: NativePlayerContainerViewController, context: Context) {
        if uiViewController.playerViewController.videoGravity != .resizeAspect {
            uiViewController.playerViewController.videoGravity = .resizeAspect
        }
        uiViewController.updateContentInsets(contentInsets)
        context.coordinator.update(container: uiViewController, url: url, isActive: isActive)
    }

    static func dismantleUIViewController(
        _ uiViewController: NativePlayerContainerViewController,
        coordinator: Coordinator
    ) {
        coordinator.tearDown(container: uiViewController)
    }

    // MARK: - Container View Controller & Pager Arbitration

    /// Public UIKit container around `AVPlayerViewController` that:
    /// 1. Insets `playerViewController.view` inside `contentInsets` (below the top
    ///    app toolbar and above the bottom home indicator) without touching `TabView`
    ///    full-bleed behavior for images/manga.
    /// 2. Installs a non-cancelling `ControlTouchObserverGestureRecognizer` on its
    ///    container view that suspends ONLY the nearest enclosing horizontal paging
    ///    `UIScrollView` (`isPagingEnabled == true`, found walking `superview` upward)
    ///    while a touch starting inside AV controls/transport is active, restoring it
    ///    on end, cancel, ignore, reset, rotation, offscreen transition, fullscreen
    ///    presentation, or teardown.
    final class NativePlayerContainerViewController: UIViewController, UIGestureRecognizerDelegate {
        let playerViewController: AVPlayerViewController
        private var contentInsets: UIEdgeInsets

        private var topConstraint: NSLayoutConstraint?
        private var leadingConstraint: NSLayoutConstraint?
        private var trailingConstraint: NSLayoutConstraint?
        private var bottomConstraint: NSLayoutConstraint?

        private weak var lockedPagerScrollView: UIScrollView?
        private var didDisablePagerScroll = false
        private var touchObserver: ControlTouchObserverGestureRecognizer?

        init(playerViewController: AVPlayerViewController, contentInsets: UIEdgeInsets) {
            self.playerViewController = playerViewController
            self.contentInsets = contentInsets
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            // Container-only identifier so XCUITest scopes native AVPlayerViewController
            // controls inside `viewer.videoPlayer` without turning the root into an opaque element.
            view.accessibilityIdentifier = "viewer.videoPlayer"

            addChild(playerViewController)
            guard let playerView = playerViewController.view else { return }
            playerView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(playerView)

            let top = playerView.topAnchor.constraint(equalTo: view.topAnchor, constant: max(0, contentInsets.top))
            let leading = playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: max(0, contentInsets.left))
            let trailing = view.trailingAnchor.constraint(equalTo: playerView.trailingAnchor, constant: max(0, contentInsets.right))
            let bottom = view.bottomAnchor.constraint(equalTo: playerView.bottomAnchor, constant: max(0, contentInsets.bottom))
            topConstraint = top
            leadingConstraint = leading
            trailingConstraint = trailing
            bottomConstraint = bottom
            NSLayoutConstraint.activate([top, leading, trailing, bottom])
            playerViewController.didMove(toParent: self)

            let observer = ControlTouchObserverGestureRecognizer()
            observer.cancelsTouchesInView = false
            observer.delaysTouchesBegan = false
            observer.delaysTouchesEnded = false
            observer.delegate = self
            observer.onControlTouchActiveChanged = { [weak self] active in
                self?.setPagerScrollSuspended(active)
            }
            view.addGestureRecognizer(observer)
            touchObserver = observer
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            releasePagerScrollLock()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            releasePagerScrollLock()
        }

        override func viewWillTransition(
            to size: CGSize,
            with coordinator: UIViewControllerTransitionCoordinator
        ) {
            super.viewWillTransition(to: size, with: coordinator)
            releasePagerScrollLock()
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.releasePagerScrollLock()
            }
        }

        func updateContentInsets(_ insets: UIEdgeInsets) {
            guard contentInsets != insets else { return }
            contentInsets = insets
            topConstraint?.constant = max(0, insets.top)
            leadingConstraint?.constant = max(0, insets.left)
            trailingConstraint?.constant = max(0, insets.right)
            bottomConstraint?.constant = max(0, insets.bottom)
        }

        func setPagerScrollSuspended(_ suspended: Bool) {
            if suspended {
                guard !didDisablePagerScroll else { return }
                guard let pager = lockedPagerScrollView ?? Self.findEnclosingPagerScrollView(from: view) else {
                    return
                }
                guard pager.isScrollEnabled else { return }
                pager.isScrollEnabled = false
                lockedPagerScrollView = pager
                didDisablePagerScroll = true
            } else {
                releasePagerScrollLock()
            }
        }

        func releasePagerScrollLock() {
            guard didDisablePagerScroll else { return }
            lockedPagerScrollView?.isScrollEnabled = true
            lockedPagerScrollView = nil
            didDisablePagerScroll = false
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            isControlInteractionTouch(touch)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Identifies touches starting on actual interactive AV controls using ONLY
        /// public UIKit hierarchy/recognizer properties (never private class-name strings
        /// or unconditional geometric catch-all bands):
        /// 1. Any enabled, visible `UIControl` ancestor inside `playerViewController.view`
        /// 2. Any internal control subview carrying an enabled pan or long-press recognizer
        private func isControlInteractionTouch(_ touch: UITouch) -> Bool {
            guard let playerView = playerViewController.view,
                  let hitView = touch.view else {
                return false
            }
            var current: UIView? = hitView
            while let subview = current, subview !== playerView, subview !== view {
                if let control = subview as? UIControl,
                   control.isEnabled,
                   !control.isHidden,
                   control.alpha > 0.01 {
                    return true
                }
                if let recognizers = subview.gestureRecognizers,
                   recognizers.contains(where: {
                       $0.isEnabled && ($0 is UIPanGestureRecognizer || $0 is UILongPressGestureRecognizer)
                   }) {
                    return true
                }
                current = subview.superview
            }
            return false
        }

        /// Walks `superview` strictly UPWARD from `view` so internal player
        /// `UIScrollView`s are never inspected, locating the nearest enclosing
        /// paging horizontal `UIScrollView` via public `UIScrollView` properties.
        private static func findEnclosingPagerScrollView(from view: UIView) -> UIScrollView? {
            var current = view.superview
            var horizontalFallback: UIScrollView?
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView {
                    if scrollView.isPagingEnabled {
                        return scrollView
                    }
                    let isHorizontal = scrollView.contentSize.width > scrollView.bounds.width + 1
                        && scrollView.contentSize.height <= scrollView.bounds.height + 2
                    if isHorizontal, horizontalFallback == nil {
                        horizontalFallback = scrollView
                    }
                }
                current = candidate.superview
            }
            return horizontalFallback
        }
    }

    /// Passive, non-cancelling gesture observer that stays `.possible` during control
    /// touches and fails on release so it never steals or blocks native AVKit controls.
    private final class ControlTouchObserverGestureRecognizer: UIGestureRecognizer {
        var onControlTouchActiveChanged: ((Bool) -> Void)?
        private var trackedTouches: Set<UITouch> = []

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            let wasEmpty = trackedTouches.isEmpty
            trackedTouches.formUnion(touches)
            if wasEmpty && !trackedTouches.isEmpty {
                onControlTouchActiveChanged?(true)
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            finishTouches(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            finishTouches(touches)
        }

        override func ignore(_ touch: UITouch, for event: UIEvent) {
            super.ignore(touch, for: event)
            finishTouches([touch])
        }

        override func reset() {
            super.reset()
            let hadTouches = !trackedTouches.isEmpty
            trackedTouches.removeAll()
            if hadTouches {
                onControlTouchActiveChanged?(false)
            }
        }

        private func finishTouches(_ touches: Set<UITouch>) {
            trackedTouches.subtract(touches)
            if trackedTouches.isEmpty {
                onControlTouchActiveChanged?(false)
                state = .failed
            }
        }
    }

    // MARK: - Playback Coordinator

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private(set) var player: AVPlayer?
        private weak var container: NativePlayerContainerViewController?
        private var lifecycle = NativePlaybackLifecycle()
        private var routeAttempts: [MediaRouteAttempt] = []

        private var timeControlObservation: NSKeyValueObservation?
        private var itemStatusObservation: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?
        private var failedToEndObserver: NSObjectProtocol?

        deinit {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            if let failedToEndObserver {
                NotificationCenter.default.removeObserver(failedToEndObserver)
            }
            timeControlObservation?.invalidate()
            itemStatusObservation?.invalidate()
        }

        @MainActor
        func configure(
            container: NativePlayerContainerViewController,
            url: URL,
            isActive: Bool
        ) {
            self.container = container
            removeAllObservers()

            let attempts = MediaRequestConfiguration.routeAttempts(for: url)
            routeAttempts = attempts
            let initialItem = Self.makePlayerItem(for: url, attempts: attempts, index: 0)

            let newPlayer = AVPlayer(playerItem: initialItem)
            // Keep `actionAtItemEnd = .none` so reaching EOF does not spontaneously
            // flip `timeControlStatus` to `.paused` before the loop check runs.
            newPlayer.actionAtItemEnd = .none
            self.player = newPlayer
            container.playerViewController.player = newPlayer

            bindPlayerObservers(to: newPlayer)
            bindItemObservers(to: initialItem, on: newPlayer)

            let action = lifecycle.configure(
                url: url,
                playerID: ObjectIdentifier(newPlayer),
                itemID: ObjectIdentifier(initialItem),
                routeAttemptCount: attempts.count,
                isActive: isActive
            )
            perform(action, on: newPlayer)
        }

        @MainActor
        func update(
            container: NativePlayerContainerViewController,
            url: URL,
            isActive: Bool
        ) {
            self.container = container
            guard let player else {
                configure(container: container, url: url, isActive: isActive)
                return
            }
            if container.playerViewController.player !== player {
                container.playerViewController.player = player
            }
            if !isActive {
                container.releasePagerScrollLock()
            }

            if lifecycle.currentURL != url {
                let attempts = MediaRequestConfiguration.routeAttempts(for: url)
                routeAttempts = attempts
                let nextItem = Self.makePlayerItem(for: url, attempts: attempts, index: 0)
                removeItemObservers()
                player.replaceCurrentItem(with: nextItem)
                bindItemObservers(to: nextItem, on: player)
                let action = lifecycle.replaceURL(
                    url,
                    itemID: ObjectIdentifier(nextItem),
                    routeAttemptCount: attempts.count,
                    isActive: isActive
                )
                perform(action, on: player)
                return
            }

            if lifecycle.isActive != isActive {
                let action = lifecycle.setActive(
                    isActive,
                    currentTime: Self.currentTimeSeconds(of: player),
                    duration: Self.finiteDurationSeconds(of: player.currentItem)
                )
                perform(action, on: player)
            }
        }

        @MainActor
        func tearDown(container: NativePlayerContainerViewController) {
            container.releasePagerScrollLock()
            lifecycle.dispose()
            removeAllObservers()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            container.playerViewController.player = nil
            container.playerViewController.delegate = nil
            self.player = nil
            self.container = nil
            routeAttempts = []
        }

        // MARK: AVPlayerViewControllerDelegate

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            let host = self.container
            Task { @MainActor in
                host?.releasePagerScrollLock()
            }
        }

        // MARK: - Observers

        @MainActor
        private func bindPlayerObservers(to player: AVPlayer) {
            timeControlObservation?.invalidate()
            let playerID = ObjectIdentifier(player)
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.handleTimeControlChange(playerID: playerID)
                }
            }
        }

        @MainActor
        private func bindItemObservers(to item: AVPlayerItem, on player: AVPlayer) {
            removeItemObservers()
            let playerID = ObjectIdentifier(player)
            let itemID = ObjectIdentifier(item)

            // Queue is `nil` so delivery thread never blocks; mutations hop explicitly to MainActor.
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDidPlayToEnd(playerID: playerID, itemID: itemID)
                }
            }

            failedToEndObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: item,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleItemFailure(playerID: playerID, itemID: itemID)
                }
            }

            itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                guard item?.status == .failed else { return }
                Task { @MainActor [weak self] in
                    self?.handleItemFailure(playerID: playerID, itemID: itemID)
                }
            }
        }

        @MainActor
        private func removeItemObservers() {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil

            if let failedToEndObserver {
                NotificationCenter.default.removeObserver(failedToEndObserver)
            }
            failedToEndObserver = nil

            itemStatusObservation?.invalidate()
            itemStatusObservation = nil
        }

        @MainActor
        private func removeAllObservers() {
            removeItemObservers()
            timeControlObservation?.invalidate()
            timeControlObservation = nil
        }

        // MARK: - Lifecycle event handlers

        @MainActor
        private func handleTimeControlChange(playerID: ObjectIdentifier) {
            guard !lifecycle.isDisposed,
                  let player,
                  ObjectIdentifier(player) == playerID else {
                return
            }
            lifecycle.observeTimeControlState(
                Self.mapTimeControlState(player.timeControlStatus),
                currentTime: Self.currentTimeSeconds(of: player),
                duration: Self.finiteDurationSeconds(of: player.currentItem),
                itemFailed: player.currentItem?.status == .failed
            )
        }

        @MainActor
        private func handleDidPlayToEnd(playerID: ObjectIdentifier, itemID: ObjectIdentifier) {
            guard let player else { return }
            let action = lifecycle.handleDidPlayToEnd(
                playerID: playerID,
                itemID: itemID,
                duration: Self.finiteDurationSeconds(of: player.currentItem),
                liveTimeControlState: Self.mapTimeControlState(player.timeControlStatus)
            )
            perform(action, on: player)
        }

        @MainActor
        private func handleLoopSeekCompleted(
            generation: Int,
            finished: Bool,
            playerID: ObjectIdentifier,
            itemID: ObjectIdentifier
        ) {
            guard let player else { return }
            let action = lifecycle.handleLoopSeekCompleted(
                generation: generation,
                finished: finished,
                playerID: playerID,
                itemID: itemID
            )
            perform(action, on: player)
        }

        @MainActor
        private func handleItemFailure(playerID: ObjectIdentifier, itemID: ObjectIdentifier) {
            guard let player,
                  let url = lifecycle.currentURL,
                  let nextIndex = lifecycle.nextRetryAttemptIndex(playerID: playerID, itemID: itemID) else {
                return
            }
            let nextItem = Self.makePlayerItem(for: url, attempts: routeAttempts, index: nextIndex)
            removeItemObservers()
            player.replaceCurrentItem(with: nextItem)
            bindItemObservers(to: nextItem, on: player)
            let action = lifecycle.bindRetryItem(itemID: ObjectIdentifier(nextItem))
            perform(action, on: player)
        }

        @MainActor
        private func perform(_ action: NativePlaybackLifecycle.Action, on player: AVPlayer) {
            switch action {
            case .none:
                break
            case .play:
                player.play()
            case .pause:
                if player.timeControlStatus != .paused {
                    lifecycle.willIssueProgrammaticPause()
                }
                player.pause()
            case let .seekToZeroAndResume(generation):
                guard let item = player.currentItem else {
                    lifecycle.cancelPendingLoopSeek()
                    return
                }
                let playerID = ObjectIdentifier(player)
                let itemID = ObjectIdentifier(item)
                player.seek(
                    to: .zero,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { [weak self] finished in
                    Task { @MainActor [weak self] in
                        self?.handleLoopSeekCompleted(
                            generation: generation,
                            finished: finished,
                            playerID: playerID,
                            itemID: itemID
                        )
                    }
                }
            }
        }

        // MARK: - Helpers

        private static func makePlayerItem(
            for url: URL,
            attempts: [MediaRouteAttempt],
            index: Int
        ) -> AVPlayerItem {
            if attempts.indices.contains(index) {
                return MediaRequestConfiguration.makePlayerItem(for: attempts[index])
            }
            return MediaRequestConfiguration.makePlayerItem(for: url)
        }

        private static func mapTimeControlState(
            _ status: AVPlayer.TimeControlStatus
        ) -> NativePlaybackLifecycle.TimeControlState {
            switch status {
            case .paused:
                return .paused
            case .waitingToPlayAtSpecifiedRate:
                return .waitingToPlay
            case .playing:
                return .playing
            @unknown default:
                return .paused
            }
        }

        private static func finiteDurationSeconds(of item: AVPlayerItem?) -> Double {
            guard let duration = item?.duration, duration.isNumeric else { return .nan }
            let seconds = duration.seconds
            return (seconds.isFinite && seconds > 0) ? seconds : .nan
        }

        private static func currentTimeSeconds(of player: AVPlayer?) -> Double {
            guard let time = player?.currentTime(), time.isNumeric else { return 0 }
            let seconds = time.seconds
            return seconds.isFinite ? max(0, seconds) : 0
        }
    }
}
