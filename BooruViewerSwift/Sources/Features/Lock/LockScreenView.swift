import Foundation
import SwiftUI

/// Outcome of one PIN submission from `PINPadView`.
enum PINPadOutcome: Equatable {
    case success
    case failure(String)
}

/// One keypad key. Letters mirror the RN keypad (`LockScreen.tsx:25-43`).
private struct KeypadKey: Identifiable {
    let digit: String
    let letters: String?

    var id: String { digit }
}

/// Four-digit PIN pad shared by the app lock and `PasscodeModalView`.
///
/// Mirrors `src/components/LockScreen.tsx`: dot indicators, error text with a shake,
/// optional biometric key, optional cancel button, and the 3x4 keypad with letter hints.
/// Haptics are intentionally absent: the native build has no haptics dependency yet.
struct PINPadView: View {
    let title: String
    let subtitle: String
    var showsCancelButton = false
    var showsBiometricButton = false
    var isWorking = false
    var onCancel: (@MainActor () -> Void)? = nil
    var onBiometric: (@MainActor () -> Void)? = nil
    let onSubmit: @MainActor (String) async -> PINPadOutcome

    @State private var pin = ""
    @State private var errorText: String?
    @State private var isErrorState = false
    @State private var isSubmitting = false
    @State private var shakeCount: CGFloat = 0

    private let gold = AppTheme.color(0xF5A623)
    private let errorRed = AppTheme.color(0xFF4D4F)

    init(
        title: String,
        subtitle: String,
        showsCancelButton: Bool = false,
        showsBiometricButton: Bool = false,
        isWorking: Bool = false,
        onCancel: (@MainActor () -> Void)? = nil,
        onBiometric: (@MainActor () -> Void)? = nil,
        onSubmit: @escaping @MainActor (String) async -> PINPadOutcome
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsCancelButton = showsCancelButton
        self.showsBiometricButton = showsBiometricButton
        self.isWorking = isWorking
        self.onCancel = onCancel
        self.onBiometric = onBiometric
        self.onSubmit = onSubmit
    }

    private static let keyRows: [[KeypadKey]] = [
        [
            KeypadKey(digit: "1", letters: nil),
            KeypadKey(digit: "2", letters: "A B C"),
            KeypadKey(digit: "3", letters: "D E F")
        ],
        [
            KeypadKey(digit: "4", letters: "G H I"),
            KeypadKey(digit: "5", letters: "J K L"),
            KeypadKey(digit: "6", letters: "M N O")
        ],
        [
            KeypadKey(digit: "7", letters: "P Q R S"),
            KeypadKey(digit: "8", letters: "T U V"),
            KeypadKey(digit: "9", letters: "W X Y Z")
        ]
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            dots
                .modifier(ShakeEffect(shakes: shakeCount))
                .animation(.linear(duration: 0.45), value: shakeCount)

            errorSlot

            Spacer(minLength: 16)

            keypad

            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.color(0x0D0E12).ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if showsCancelButton, let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.textMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                .padding(.top, 8)
                .padding(.trailing, 10)
            }
        }
        .onChange(of: title) { _, _ in
            if !isSubmitting && !isErrorState {
                pin = ""
                errorText = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(gold)
                .frame(width: 64, height: 64)
                .background(gold.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(gold.opacity(0.3), lineWidth: 1.5))
                .padding(.bottom, 12)

            Text(title)
                .font(.system(size: 22, weight: .bold))
                .kerning(-0.3)
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 280)
        }
        .padding(.top, 10)
    }

    // MARK: - Dots

    private var dots: some View {
        HStack(spacing: 20) {
            ForEach(0..<SecurityService.pinLength, id: \.self) { index in
                dotView(filled: index < pin.count)
            }
        }
        .padding(.vertical, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pin.count) of \(SecurityService.pinLength) digits entered")
    }

    @ViewBuilder
    private func dotView(filled: Bool) -> some View {
        if filled {
            Circle()
                .fill(isErrorState ? errorRed : gold)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle()
                        .fill(Color.white.opacity(0.4))
                        .padding(3)
                )
                .overlay(
                    Circle().stroke(isErrorState ? errorRed : gold, lineWidth: 1.5)
                )
        } else {
            Circle()
                .fill(Color.white.opacity(0.05))
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                )
        }
    }

    private var errorSlot: some View {
        Text(errorText ?? " ")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(errorRed)
            .multilineTextAlignment(.center)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .opacity(errorText == nil ? 0 : 1)
            .accessibilityLabel(errorText ?? "")
    }

    // MARK: - Keypad

    private var keypad: some View {
        VStack(spacing: 14) {
            ForEach(Self.keyRows.indices, id: \.self) { index in
                HStack(spacing: 24) {
                    ForEach(Self.keyRows[index]) { key in
                        keyButton(key)
                    }
                }
            }

            bottomRow
        }
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
    }

    private func keyButton(_ key: KeypadKey) -> some View {
        Button {
            press(key.digit)
        } label: {
            VStack(spacing: 1) {
                Text(key.digit)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                if let letters = key.letters {
                    Text(letters)
                        .font(.system(size: 9, weight: .bold))
                        .kerning(1.4)
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .frame(width: 72, height: 72)
            .background(Color.white.opacity(0.07), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || isWorking)
        .accessibilityLabel(key.digit)
    }

    /// `[delete][0][biometric]`, the same 72pt three-slot row as the digit rows.
    ///
    /// Delete is always mounted (never swapped for a spacer): a mistyped PIN has to be
    /// correctable, and an empty cropped key used to leave the bottom row blank on both
    /// sides of the zero. Before the first digit it stays visible but dimmed and inert.
    private var bottomRow: some View {
        HStack(spacing: 24) {
            deleteButton

            keyButton(KeypadKey(digit: "0", letters: nil))

            if showsBiometricButton, let onBiometric {
                Button(action: onBiometric) {
                    Image(systemName: "faceid")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(gold)
                        .frame(width: 72, height: 72)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting || isWorking)
                .accessibilityLabel("Unlock with biometrics")
            } else {
                Color.clear.frame(width: 72, height: 72)
            }
        }
    }

    private var deleteButton: some View {
        let canDelete = !pin.isEmpty && !isSubmitting && !isWorking

        return Button {
            deleteLast()
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(canDelete ? AppTheme.textPrimary : AppTheme.color(0x686E7D))
                .frame(width: 72, height: 72)
                .background(Color.white.opacity(canDelete ? 0.07 : 0), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(canDelete ? 0.08 : 0), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canDelete)
        .accessibilityLabel("Delete last digit")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 12, weight: .semibold))
            Text("End-to-end on-device security")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(AppTheme.color(0x686E7D))
        .padding(.top, 10)
    }

    // MARK: - Actions

    private func press(_ digit: String) {
        guard !isSubmitting, !isWorking, pin.count < SecurityService.pinLength else { return }
        errorText = nil
        isErrorState = false
        pin += digit
        guard pin.count == SecurityService.pinLength else { return }
        let submitted = pin
        Task { await submit(submitted) }
    }

    private func deleteLast() {
        guard !pin.isEmpty, !isSubmitting else { return }
        pin.removeLast()
        errorText = nil
        isErrorState = false
    }

    private func submit(_ value: String) async {
        isSubmitting = true
        defer { isSubmitting = false }

        let outcome = await onSubmit(value)
        switch outcome {
        case .success:
            pin = ""
            errorText = nil
            isErrorState = false
        case .failure(let message):
            errorText = message
            isErrorState = true
            withAnimation(.linear(duration: 0.45)) {
                shakeCount += 1
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            pin = ""
            isErrorState = false
        }
    }
}

/// Horizontal shake used when a PIN is rejected.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 13
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = travel * sin(shakes * .pi * 2)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

/// Full-screen lock overlay bound to `AppLockController`.
///
/// - `isLocked` mounts the PIN pad with the biometric key and the PIN fallback
///   (`LockScreen.tsx` unlock mode).
/// - `isPrivacyCurtainVisible` draws the `#0D0E12` curtain **above** the pad, so an iOS
///   system prompt never exposes app content and the pad survives the prompt
///   (`App.tsx:265-266`). The pad is kept mounted while the curtain shows, which also keeps
///   the biometric auto-prompt from being cancelled by the scene-phase change.
///
/// Usage: overlay it above the app content, e.g.
/// `content.overlay { LockScreenView(controller: lockController) }`.
///
/// Do **not** add `.ignoresSafeArea()` to the overlay: the pad must stay inside the top
/// safe area so the padlock badge never lands on the Dynamic Island, the notch, or the
/// status bar. The opaque layers bleed to the screen edges by themselves.
struct LockScreenView: View {
    let controller: AppLockController
    var securityService: SecurityService = SecurityService()
    /// When false, the biometric key and the auto-prompt are suppressed and only the PIN pad is offered.
    var useBiometrics: Bool = true

    init(
        controller: AppLockController,
        securityService: SecurityService = SecurityService(),
        useBiometrics: Bool = true
    ) {
        self.controller = controller
        self.securityService = securityService
        self.useBiometrics = useBiometrics
    }

    var body: some View {
        ZStack {
            if controller.isLocked || controller.isPrivacyCurtainVisible {
                // Full-bleed opaque layer: it paints under the status bar/Dynamic Island and
                // the home indicator, and swallows taps that land outside the safe area while
                // the app is hidden.
                AppTheme.color(0x0D0E12)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }

            if controller.isLocked {
                PINPadView(
                    title: "Enter Passcode",
                    subtitle: "Enter your 4-digit PIN to access the app",
                    showsBiometricButton: useBiometrics && securityService.canUseBiometrics(),
                    onBiometric: { Task { await controller.unlockWithBiometrics() } },
                    onSubmit: { pin in
                        let unlocked = await controller.unlock(withPIN: pin)
                        return unlocked ? .success : .failure("Incorrect Passcode")
                    }
                )
                .task {
                    // RN auto-triggers biometrics when the lock screen appears (LockScreen.tsx:104-107).
                    guard useBiometrics, controller.isLocked, securityService.canUseBiometrics() else { return }
                    await controller.unlockWithBiometrics()
                }
            }

            if controller.isPrivacyCurtainVisible {
                privacyCurtain
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.15), value: controller.isPrivacyCurtainVisible)
        .preferredColorScheme(.dark)
    }

    private var privacyCurtain: some View {
        ZStack {
            AppTheme.color(0x0D0E12)
                .ignoresSafeArea()
            Image(systemName: "lock.shield")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.white.opacity(0.1))
        }
        .accessibilityHidden(true)
    }
}
