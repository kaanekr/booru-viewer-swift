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
///
/// Presentation is stock iOS 26: the keys and the close control are plain `Button`s in the
/// system Liquid Glass styles (`.glass`, `.glassProminent`) with SF Symbols and semantic
/// fonts. Nothing draws a hand-made circular control lookalike, and the 72 pt key lanes /
/// 44 pt close lane are real layout so Dynamic Type only changes the glyph size.
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

    /// Used only to drop the keypad's letter hints at accessibility sizes: the hints would
    /// otherwise overflow the 72 pt key lane while the digit itself still fits.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let pinErrorColor = AppTheme.danger

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
        // The pad is ~634 pt tall at the default size and taller at accessibility sizes, so it
        // scrolls only when it cannot fit. The `GeometryReader` measures the safe-area rect (the
        // lock overlay is never `.ignoresSafeArea`d), and `minHeight` fills exactly that rect, so
        // the pad is vertically centred below the Dynamic Island while it fits and otherwise
        // keeps its natural height and scrolls from the top instead of clipping the header,
        // keypad, or footer. Scroll content holds no unbounded `Spacer` and no negative padding.
        GeometryReader { proxy in
            ScrollView(.vertical) {
                content
                    // The scroll view hands its content an unbounded height, so the bound is
                    // restated here: `minHeight` equals the safe-area height while the pad fits;
                    // when the pad is taller its intrinsic height wins and it scrolls.
                    .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Semantic surface: under the lock screen's forced dark scheme this resolves to the
        // system dark background, so the pad matches the opaque curtain instead of carrying
        // its own hard-coded near-black. The curtain itself stays opaque (see `LockScreenView`).
        .background(AppTheme.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if showsCancelButton, let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .frame(
                            minWidth: AppTheme.Spacing.minimumHitTarget,
                            minHeight: AppTheme.Spacing.minimumHitTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("passcode.closeButton")
                .padding(.top, 8)
                .padding(.trailing, 10)
            }
        }
        .onChange(of: title) { _, _ in
            pin = ""
            errorText = nil
            isErrorState = false
        }
    }

    /// The pad itself: header, dots, error slot, keypad, footer.
    ///
    /// No flexible `Spacer`: inside a `ScrollView` the proposal is unbounded, so a spacer
    /// would either collapse or try to grow without limit. The 16 pt gap above the keypad is a
    /// fixed `.padding`, and vertical centring comes from the host `frame(minHeight:)`, which
    /// is skipped entirely when the content is taller than the safe area.
    private var content: some View {
        VStack(spacing: 0) {
            header

            dots
                .modifier(ShakeEffect(shakes: shakeCount))
                .animation(.linear(duration: 0.45), value: shakeCount)

            errorSlot

            keypad
                .padding(.top, 16)

            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(.title, weight: .semibold))
                .foregroundStyle(AppTheme.goldAccent)
                .frame(minWidth: 64, minHeight: 64)
                .padding(.bottom, 12)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            Text(subtitle)
                .font(AppTheme.Typography.secondary)
                .foregroundStyle(AppTheme.textSecondary)
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

    /// Filled dot = the accent; empty dot = a quiet semantic fill with a hairline. The
    /// error state recolours the filled dots with the semantic danger colour.
    @ViewBuilder
    private func dotView(filled: Bool) -> some View {
        Circle()
            .fill(filled ? (isErrorState ? pinErrorColor : AppTheme.goldAccent) : AppTheme.chip)
            .frame(width: 16, height: 16)
            .overlay(
                Circle().stroke(
                    filled ? Color.clear : AppTheme.chipBorder,
                    lineWidth: 1
                )
            )
    }

    private var errorSlot: some View {
        Text(errorText ?? " ")
            .font(AppTheme.Typography.secondary.weight(.semibold))
            .foregroundStyle(pinErrorColor)
            .multilineTextAlignment(.center)
            // Minimum, not fixed: the slot reserves its line at default sizes and still grows
            // instead of clipping the message at accessibility sizes.
            .frame(minHeight: 22)
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

    /// One digit key: native `.glass` button, the digit in a semantic font and the letter
    /// hints as a caption. The 72 pt lane is the label, so the glass draws exactly the
    /// control and the tap target is the whole key.
    private func keyButton(_ key: KeypadKey) -> some View {
        Button {
            press(key.digit)
        } label: {
            VStack(spacing: 1) {
                Text(key.digit)
                    .font(.system(.title2, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                // Letter hints are decoration: at accessibility sizes they are dropped so the
                // digit keeps the 72 pt lane instead of overflowing it.
                if let letters = key.letters, !dynamicTypeSize.isAccessibilitySize {
                    Text(letters)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.textMuted)
                }
            }
            // A minimum lane, not a fixed one: at accessibility sizes the key grows with the
            // digit instead of clipping it. 72 pt is the default-size keypad lane.
            .frame(minWidth: 72, minHeight: 72)
            .contentShape(Circle())
        }
        .buttonStyle(.glass)
        // The native border shape makes the glass a circle; no hand-drawn fill or stroke.
        .buttonBorderShape(.circle)
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
                    // Explicit dark glyph: the prominent glass plate is tinted gold, and the
                    // style's default glyph colour (white) is only ~2.09:1 on #F5A623, below
                    // the 3:1 large-glyph floor. The brand's on-gold ink fixes the contrast
                    // while the native style, plate, and 72 pt lane stay intact.
                    Image(systemName: "faceid")
                        .font(.system(.title2, weight: .medium))
                        .foregroundStyle(AppTheme.goldAccentText)
                        .frame(minWidth: 72, minHeight: 72)
                        .contentShape(Circle())
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                // Gold plate for the primary unlock shortcut (the RN keypad's gold biometric
                // key). The dark glyph above is what keeps the symbol legible on that plate.
                .tint(AppTheme.goldAccent)
                .disabled(isSubmitting || isWorking)
                .accessibilityLabel("Unlock with biometrics")
            } else {
                // Invisible stand-in for the biometric slot: it carries the same glyph metrics
                // as the real key, so the zero stays centred with or without biometrics at any
                // Dynamic Type size. Nothing is drawn and nothing is tappable.
                Image(systemName: "faceid")
                    .font(.system(.title2, weight: .medium))
                    .frame(minWidth: 72, minHeight: 72)
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
    }

    private var deleteButton: some View {
        let canDelete = !pin.isEmpty && !isSubmitting && !isWorking

        return Button {
            deleteLast()
        } label: {
            Image(systemName: "delete.left")
                .font(.system(.title3, weight: .medium))
                .frame(minWidth: 72, minHeight: 72)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        // Same circle as the digit keys and the biometric key.
        .buttonBorderShape(.circle)
        // One disabled look only: `.disabled` dims the key and drops its interaction, so the
        // key keeps its 72 pt lane and row geometry without a second manual `.opacity`.
        .disabled(!canDelete)
        .accessibilityLabel("Delete last digit")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
                .font(AppTheme.Typography.caption)
            Text("End-to-end on-device security")
                .font(AppTheme.Typography.caption)
        }
        .foregroundStyle(AppTheme.textMuted)
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
/// - `isPrivacyCurtainVisible` draws an **opaque** curtain above the pad, so an iOS system
///   prompt never exposes app content and the pad survives the prompt
///   (`App.tsx:265-266`). The pad is kept mounted while the curtain shows, which also keeps
///   the biometric auto-prompt from being cancelled by the scene-phase change. The curtain is
///   deliberately *not* Liquid Glass: glass is translucent, and the whole point of the cover
///   is that nothing behind the app's UI is readable while the scene is inactive.
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
                // the app is hidden. `AppTheme.background` is a fully opaque system colour
                // (no material, no alpha), so nothing behind it is readable. Its appearance is
                // never animated: a 150 ms fade would briefly show the app snapshot underneath.
                AppTheme.background
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .transaction { $0.animation = nil }
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No container-level animation: every layer here is a security cover, so mounts and
        // unmounts are immediate. The lock/shake animations live inside `PINPadView`.
        .preferredColorScheme(.dark)
    }

    /// Opaque full-bleed cover: the same system background as the lock pad, plus a faint
    /// shield watermark. Opaque by design (see the type docs), so no glass/material is used.
    ///
    /// There is no opacity transition: the cover has to be *immediately* opaque when the scene
    /// goes inactive/background, so the whole subtree is mounted with animation disabled rather
    /// than cross-fading in from transparent.
    private var privacyCurtain: some View {
        ZStack {
            // Bottom edge (home indicator region) included: `ignoresSafeArea` covers all edges.
            AppTheme.background
                .ignoresSafeArea()
            Image(systemName: "lock.shield")
                .font(.system(.largeTitle, weight: .light))
                .foregroundStyle(AppTheme.textMuted.opacity(0.5))
        }
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}
