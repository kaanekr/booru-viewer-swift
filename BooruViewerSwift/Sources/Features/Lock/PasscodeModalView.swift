import SwiftUI

/// Which passcode flow the modal runs. Mirrors RN `PasscodeModalMode`.
enum PasscodeMode: String, Identifiable, CaseIterable {
    /// Enter a new PIN, then confirm it.
    case setup
    /// Verify the current PIN, enter a new one, then confirm it.
    case change
    /// Verify the current PIN, then remove the lock.
    case disable

    var id: String { rawValue }
}

/// 4-digit PIN modal for setting, changing, or removing the app-lock PIN.
///
/// Mirrors `src/components/PasscodeModal.tsx`: the view owns only the step machine and
/// delegates every security operation to the injected closures, so `SettingsViewModel`
/// stays the single owner of `SecurityService` state.
///
/// This is the **app-lock PIN** (a 4-digit value hashed by `SecurityService`), not the iOS
/// device passcode: the modal never offers a `LocalAuthentication` device-passcode fallback
/// and every step still goes through the injected `verify` / `setPasscode` / `clearPasscode`.
///
/// Presentation is stock iOS 26: a `NavigationStack` around the pad with the system toolbar
/// Cancel button (the bar draws its own glass) instead of a hand-positioned overlay glyph.
/// The sheet's drag indicator is the system default rather than hidden.
struct PasscodeModalView: View {
    let mode: PasscodeMode
    /// RN `SecurityService.verifyPasscode` collapse.
    let verify: @MainActor (String) async -> Bool
    /// Hashes and stores the PIN; also enables the lock in `AppSettings`.
    let setPasscode: @MainActor (String) async throws -> Void
    /// Removes the stored hash and disables the lock.
    let clearPasscode: @MainActor () async throws -> Void
    var onSuccess: @MainActor () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var step = 1
    @State private var firstPIN = ""

    init(
        mode: PasscodeMode,
        verify: @escaping @MainActor (String) async -> Bool,
        setPasscode: @escaping @MainActor (String) async throws -> Void,
        clearPasscode: @escaping @MainActor () async throws -> Void,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) {
        self.mode = mode
        self.verify = verify
        self.setPasscode = setPasscode
        self.clearPasscode = clearPasscode
        self.onSuccess = onSuccess
    }

    var body: some View {
        NavigationStack {
            PINPadView(
                title: title,
                subtitle: subtitle,
                showsCancelButton: false,
                onSubmit: { pin in await handle(pin) }
            )
            .navigationTitle("App Passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .accessibilityIdentifier("passcode.cancel")
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    // MARK: - Copy (RN PasscodeModal.tsx:38-72)

    private var title: String {
        switch mode {
        case .setup:
            return step == 1 ? "Set a New Passcode" : "Verify Passcode"
        case .change:
            switch step {
            case 1: return "Current Passcode"
            case 2: return "New Passcode"
            default: return "Verify New Passcode"
            }
        case .disable:
            return "Turn Off Lock"
        }
    }

    private var subtitle: String {
        switch mode {
        case .setup:
            return step == 1
                ? "Enter a 4-digit PIN to lock the app"
                : "Re-enter the 4-digit PIN you set"
        case .change:
            switch step {
            case 1: return "Enter your current PIN to continue"
            case 2: return "Set your new 4-digit PIN"
            default: return "Re-enter to confirm your new PIN"
            }
        case .disable:
            return "Enter your current PIN to remove the passcode lock"
        }
    }

    // MARK: - Step machine

    private func handle(_ pin: String) async -> PINPadOutcome {
        switch mode {
        case .setup:
            if step == 1 {
                firstPIN = pin
                step = 2
                return .success
            }
            guard pin == firstPIN else {
                firstPIN = ""
                step = 1
                return .failure("Passcodes did not match! Enter again.")
            }
            do {
                try await setPasscode(pin)
                onSuccess()
                dismiss()
                return .success
            } catch {
                return .failure("Could not save your passcode.")
            }

        case .change:
            if step == 1 {
                guard await verify(pin) else {
                    return .failure("Current passcode is incorrect!")
                }
                step = 2
                return .success
            }
            if step == 2 {
                firstPIN = pin
                step = 3
                return .success
            }
            guard pin == firstPIN else {
                firstPIN = ""
                step = 2
                return .failure("New passcodes did not match! Try again.")
            }
            do {
                try await setPasscode(pin)
                onSuccess()
                dismiss()
                return .success
            } catch {
                return .failure("Could not save your passcode.")
            }

        case .disable:
            guard await verify(pin) else {
                return .failure("Current passcode is incorrect!")
            }
            do {
                try await clearPasscode()
                onSuccess()
                dismiss()
                return .success
            } catch {
                return .failure("Could not remove your passcode.")
            }
        }
    }
}
