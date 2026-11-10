import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Application entry point.
///
/// Builds the shared `AppContainer`, shows `RootTabView`, forces the dark appearance, and turns
/// SwiftUI scene-phase changes into the lock controller's `AppScenePhase` events.
@main
@MainActor
struct BooruViewerApp: App {
    @State private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.configureNavigationBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(container: container)
                .preferredColorScheme(.dark)
                .task {
                    await container.bootstrap()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                await container.lockController.handleScenePhase(Self.appScenePhase(phase))
            }
        }
    }

    // MARK: - UIKit bars

    /// Paints the navigation bar with the app palette.
    ///
    /// The system tab bar is deliberately left alone: it uses the stock SwiftUI appearance, so
    /// the app keeps the plain default `TabView` look. `RootTabView`'s root
    /// `.background(AppTheme.background.ignoresSafeArea())` supplies the colour behind it.
    private static func configureNavigationBarAppearance() {
        #if canImport(UIKit)
        let background = UIColor(AppTheme.background)

        let navigationBarAppearance = UINavigationBarAppearance()
        navigationBarAppearance.configureWithOpaqueBackground()
        navigationBarAppearance.backgroundColor = background
        navigationBarAppearance.shadowColor = .clear
        navigationBarAppearance.titleTextAttributes = [.foregroundColor: UIColor(AppTheme.textPrimary)]
        navigationBarAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor(AppTheme.textPrimary)]

        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = navigationBarAppearance
        navigationBar.compactAppearance = navigationBarAppearance
        navigationBar.scrollEdgeAppearance = navigationBarAppearance
        #endif
    }

    /// SwiftUI's `ScenePhase` mapped onto the lock controller's own phase type.
    private static func appScenePhase(_ phase: ScenePhase) -> AppScenePhase {
        switch phase {
        case .active:
            return .active
        case .inactive:
            return .inactive
        case .background:
            return .background
        @unknown default:
            return .inactive
        }
    }
}
