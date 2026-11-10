import Foundation
import Observation

/// The scene phases the lock reacts to. Mirrors the RN `AppStateStatus` values used in
/// `App.tsx:176-190`. Named `AppScenePhase` so it cannot collide with SwiftUI's `ScenePhase`.
enum AppScenePhase: Sendable, Equatable {
    case active
    case inactive
    case background
}

/// App-lock state machine: cold-start lock, background auto-lock, and the privacy curtain.
///
/// Mirrors `App.tsx`:
/// - cold start locks when a passcode is enabled (App.tsx:150-157),
/// - `inactive` only shows the privacy curtain so the lock pad is never mounted over an
///   iOS system dialog (App.tsx:176-178),
/// - `background` always locks when a passcode is enabled (App.tsx:179-190); RN's handler
///   does not consult `autoLockImmediately`, so neither does this controller,
/// - the curtain is the `!isForeground || checkingBackgroundLock` cover (App.tsx:265-266).
@MainActor
@Observable
final class AppLockController {
    /// True while the lock screen must cover the app.
    private(set) var isLocked = false
    /// True while the app is not fully foreground, or a background lock check is running.
    private(set) var isPrivacyCurtainVisible = false
    /// True while the asynchronous background lock check is in flight (App.tsx:181-189).
    private(set) var isCheckingBackgroundLock = false

    private let service: SecurityService
    private let settings: any SettingsStoring

    init(
        service: SecurityService = SecurityService(),
        settings: any SettingsStoring
    ) {
        self.service = service
        self.settings = settings
    }

    // MARK: - Launch

    /// RN `initApp` (App.tsx:148-163): lock before first render when the passcode is on.
    /// Never throws: a settings or Keychain failure leaves the app unlocked, matching
    /// `isPasscodeEnabled`'s non-throwing contract on the RN side.
    func prepareForLaunch() async {
        let config = await currentConfig()
        isLocked = (try? service.isPasscodeEnabled(config: config)) ?? false
    }

    // MARK: - Scene phase

    func handleScenePhase(_ phase: AppScenePhase) async {
        switch phase {
        case .active:
            // Coming back to the foreground always removes the cover; the lock screen covers
            // the content on its own when `isLocked` is true.
            isPrivacyCurtainVisible = false
        case .inactive:
            // iOS system prompts emit `inactive`: cover the content, but do not mount a PIN pad
            // on top of an existing system dialog (App.tsx:176-178).
            isPrivacyCurtainVisible = true
        case .background:
            isPrivacyCurtainVisible = true
            await lockForBackground()
        }
    }

    /// App.tsx:179-190: `.background` always locks when a passcode is enabled — the RN handler
    /// never consults `autoLockImmediately`. An unreadable config falls back to `true`, so a
    /// settings read or Keychain failure still locks (RN's `catch` sets the lock as well).
    private func lockForBackground() async {
        isCheckingBackgroundLock = true
        defer { isCheckingBackgroundLock = false }

        let config = await currentConfig()
        if (try? service.isPasscodeEnabled(config: config)) ?? true {
            isLocked = true
        }
    }

    // MARK: - Manual lock

    func lockNow() {
        isLocked = true
    }

    // MARK: - Unlock

    /// Returns `false` for a wrong PIN; state only changes on success.
    @discardableResult
    func unlock(withPIN pin: String) async -> Bool {
        let config = await currentConfig()
        guard (try? service.verifyPasscode(pin, config: config)) == true else { return false }
        finishUnlock()
        return true
    }

    /// Returns `false` when biometrics are disabled in settings, unavailable, or the prompt
    /// fails/cancels. The caller keeps the PIN pad visible in that case (RN
    /// `disableDeviceFallback` behaviour, securityService.ts:176).
    @discardableResult
    func unlockWithBiometrics(prompt: String = "Verify to unlock the app") async -> Bool {
        let config = await currentConfig()
        guard config.useBiometrics else { return false }
        guard await service.authenticateWithBiometrics(prompt: prompt) else { return false }
        finishUnlock()
        return true
    }

    private func finishUnlock() {
        isLocked = false
        isPrivacyCurtainVisible = false
    }

    // MARK: - Settings

    private func currentConfig() async -> SecurityConfig {
        (try? await settings.load())?.security ?? SecurityConfig()
    }
}
