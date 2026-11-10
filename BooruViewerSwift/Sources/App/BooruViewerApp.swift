import SwiftUI

/// Application entry point.
///
/// Builds the shared `AppContainer`, shows `RootTabView`, keeps the dark appearance, and turns
/// SwiftUI scene-phase changes into the lock controller's `AppScenePhase` events.
/// Navigation bars, tab bars, and scroll edges use system iOS 26 Liquid Glass with no global
/// `UIAppearance` overrides.
@main
@MainActor
struct BooruViewerApp: App {
    @State private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

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
