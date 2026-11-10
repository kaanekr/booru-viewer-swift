import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared building blocks

/// Presents `SettingsViewModel.alert` through the stock system alert.
///
/// Wired exactly like the previous `.alert(item:)` pass: the home page and every subpage
/// attach it to the same payload, so the page that raised an action always has its own
/// presentation host. Dismissing clears `model.alert`, which leaves nothing for another
/// host to re-present: one action still shows at most one alert.
private struct SettingsAlertModifier: ViewModifier {
    let model: SettingsViewModel

    func body(content: Content) -> some View {
        content.alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { presented in
                    if !presented { model.alert = nil }
                }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { state in
            Text(state.message)
        }
    }
}

extension View {
    /// Attaches the settings alert to a page.
    func settingsAlert(_ model: SettingsViewModel) -> some View {
        modifier(SettingsAlertModifier(model: model))
    }
}

/// One row's label: optional icon, title, optional subtitle, optional trailing value.
///
/// The enclosing `Section` supplies the card fill, separators, inset and disclosure
/// chevron, so this view paints nothing but text and a tinted glyph.
struct SettingsRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var value: String? = nil
    var isDanger = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.item) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.Icon.small, weight: .semibold))
                    .foregroundStyle(isDanger ? AppTheme.danger : AppTheme.primary)
                    .frame(minWidth: 22, alignment: .center)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(isDanger ? AppTheme.danger : AppTheme.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AppTheme.Spacing.item)

            if let value {
                Text(value)
                    .font(AppTheme.Typography.secondary)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Native `Toggle` row with an optional subtitle and icon.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    let isOn: Bool
    var isBusy = false
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { isOn },
                set: { value in
                    guard !isBusy else { return }
                    onChange(value)
                }
            )
        ) {
            HStack(spacing: AppTheme.Spacing.item) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: AppTheme.Icon.small, weight: .semibold))
                        .foregroundStyle(AppTheme.primary)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.textPrimary)

                    if let subtitle {
                        Text(subtitle)
                            .font(AppTheme.Typography.secondary)
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(AppTheme.primary)
        .disabled(isBusy)
    }
}

/// Full-width action row. Destructive actions use the system red through `ButtonRole`.
struct SettingsActionButton: View {
    let title: String
    var isSecondary = false
    var isDanger = false
    var isBusy = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(role: buttonRole, action: action) {
            HStack(spacing: AppTheme.Spacing.item) {
                Spacer(minLength: 0)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(title)
                        .font(AppTheme.Typography.body)
                        .fontWeight(isSecondary ? .regular : .semibold)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .disabled(isDisabled || isBusy)
    }

    /// `nil` for a standard button so the row keeps the accent; destructive rows go red.
    private var buttonRole: ButtonRole? {
        isDanger ? .destructive : nil
    }
}

/// Labeled text field row (`LabeledContent` + `TextField` / `SecureField`).
struct SettingsField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var isSecure = false
    var isNumeric = false
    var isURL = false

    var body: some View {
        LabeledContent {
            Group {
                if isSecure {
                    SecureField("", text: $text, prompt: Text(placeholder))
                } else {
                    TextField("", text: $text, prompt: Text(placeholder))
                }
            }
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(isNumeric ? .numberPad : (isURL ? .URL : .default))
            .accessibilityLabel(label)
        } label: {
            Text(label)
                .font(AppTheme.Typography.body)
        }
    }
}

/// Muted helper copy; used as a `Section` footer so the system styles and insets it.
struct SettingsHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTheme.Typography.secondary)
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Green confirmation line (RN `ui.status`).
struct SettingsStatusText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTheme.Typography.secondary)
            .foregroundStyle(AppTheme.success)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Brand mark used by the source rows and heroes (`SourceCatalog.tsx` mark).
struct SourceMarkBadge: View {
    let entry: SourceSheetView.Entry
    var size: CGFloat = 40

    var body: some View {
        Text(entry.initials)
            .font(.system(size: size * (entry.initials.count > 1 ? 0.32 : 0.42), weight: .bold))
            .foregroundStyle(AppTheme.color(entry.colorHex))
            .frame(width: size, height: size)
            .background(AppTheme.color(entry.colorHex, opacity: 0.16), in: Circle())
            .overlay(
                Circle()
                    .stroke(AppTheme.color(entry.colorHex, opacity: 0.35), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Sources

/// Source picker plus a per-source settings entry, mirroring the RN sources page.
struct SourcesSettingsView: View {
    let model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                ForEach(entries) { entry in
                    sourceRow(entry)
                }
            } header: {
                Text("All sources")
            } footer: {
                SettingsHint(text: "Keys are saved on this device only. Each source needs its own key.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sources & API Keys")
        .navigationBarTitleDisplayMode(.inline)
        .settingsAlert(model)
    }

    private var entries: [SourceSheetView.Entry] {
        SourceSheetView.visibleCatalog
    }

    /// Tap the row to switch source; the trailing gear pushes that source's detail page.
    private func sourceRow(_ entry: SourceSheetView.Entry) -> some View {
        let isActive = entry.id == model.activeSourceID

        return HStack(spacing: AppTheme.Spacing.item) {
            Button {
                Task { await model.selectSource(entry.id) }
            } label: {
                HStack(spacing: AppTheme.Spacing.item) {
                    SourceMarkBadge(entry: entry, size: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(AppTheme.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(AppTheme.textPrimary)

                            if isActive {
                                Text("ACTIVE")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(AppTheme.primary)
                            }
                        }

                        Text("\(entry.kind) • \(entry.host)")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
                .contentShape(Rectangle())
            }
            // Borderless keeps the row's two tap targets independent: the switch button and
            // the gear link each own their bounds instead of the whole row.
            .buttonStyle(.borderless)
            .disabled(model.busy == .source)
            .accessibilityLabel(isActive ? "\(entry.name), active source" : "Use \(entry.name)")
            .accessibilityAddTraits(isActive ? [.isSelected] : [])

            NavigationLink {
                SourceDetailSettingsView(source: entry.id, model: model)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: AppTheme.Icon.small, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)
                    // Real layout, not a painted overlay: the gear owns a 44 pt target.
                    .frame(
                        minWidth: AppTheme.Spacing.minimumHitTarget,
                        minHeight: AppTheme.Spacing.minimumHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(entry.name) settings")
        }
    }
}

/// One source's details: switch button, API credentials for Gelbooru / Rule34, website link.
struct SourceDetailSettingsView: View {
    let source: SourceID
    let model: SettingsViewModel

    @Environment(\.openURL) private var openURL

    init(source: SourceID, model: SettingsViewModel) {
        self.source = source
        self.model = model
    }

    private var entry: SourceSheetView.Entry {
        SourceSheetView.entry(for: source)
    }

    var body: some View {
        Form {
            Section {
                hero
            }

            // The switch action lives in its own native row, not inside the hero block:
            // otherwise the whole hero would be one huge tap target.
            if model.activeSourceID != source {
                Section {
                    SettingsActionButton(
                        title: "Use \(entry.name)",
                        isBusy: model.busy == .source,
                        action: { Task { await model.selectSource(source) } }
                    )
                }
            }

            if KeychainStore.authAccount(for: source) != nil {
                authSection
            } else {
                Section {
                    Label("No manual API key needed", systemImage: "checkmark.shield")
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.textSecondary)
                } footer: {
                    SettingsHint(text: "Connection preferences apply across all sources.")
                }
            }

            Section("Source details") {
                Button {
                    openWebsite()
                } label: {
                    SettingsRow(
                        title: "Website",
                        subtitle: entry.host,
                        systemImage: "globe"
                    )
                }

                NavigationLink {
                    NetworkSettingsView(model: model)
                } label: {
                    SettingsRow(
                        title: "Connection settings",
                        subtitle: "App-wide relay & connection diagnostics",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .settingsAlert(model)
    }

    /// Non-interactive source identity. The switch action is a separate row in `body`, so the
    /// hero itself is pure metadata and cannot swallow taps.
    private var hero: some View {
        let isActive = model.activeSourceID == source

        return VStack(alignment: .center, spacing: AppTheme.Spacing.item) {
            SourceMarkBadge(entry: entry, size: 56)

            Text(entry.name)
                .font(AppTheme.Typography.screenTitle)
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(entry.kind) source")
                .font(AppTheme.Typography.secondary)
                .foregroundStyle(AppTheme.textSecondary)

            Text(Self.description(for: source))
                .font(AppTheme.Typography.secondary)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if isActive {
                Label("Your current source", systemImage: "checkmark")
                    .font(AppTheme.Typography.secondary)
                    .foregroundStyle(AppTheme.primary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var authSection: some View {
        @Bindable var model = model
        let isRule34 = source == .rule34
        let saved = model.savedAuth(for: source)
        let hasAnyKey = !model.auth(for: source).apiKey.isEmpty
            || !model.auth(for: source).userID.isEmpty
            || !saved.apiKey.isEmpty

        // Every statement is a direct child of the `Section` builder, so each control gets
        // its own native row instead of sharing one.
        return Section {
            HStack(spacing: AppTheme.Spacing.item) {
                Image(systemName: "key")
                    .font(.system(size: AppTheme.Icon.standard, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)
                    .accessibilityHidden(true)

                Text(isRule34 ? "API key required" : "Connect your account")
                    .font(AppTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer(minLength: 0)
            }

            SettingsHint(
                text: isRule34
                    ? "Rule34 requires your user ID and API key to load posts."
                    : "A Gelbooru API key enables DAPI access and higher request limits."
            )

            if let accountURL = URL(string: accountURLString) {
                Link(destination: accountURL) {
                    HStack(spacing: 4) {
                        Text("Get your API key")
                            .font(AppTheme.Typography.body)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
            }

            SettingsField(
                label: "User ID",
                placeholder: isRule34 ? "Rule34 user_id" : "Gelbooru user_id",
                text: isRule34 ? $model.rule34Auth.userID : $model.gelbooruAuth.userID,
                isNumeric: true
            )

            SettingsField(
                label: "API key",
                placeholder: isRule34 ? "Rule34 api_key" : "Gelbooru api_key",
                text: isRule34 ? $model.rule34Auth.apiKey : $model.gelbooruAuth.apiKey,
                isSecure: true
            )

            SettingsActionButton(
                title: "Save",
                isBusy: model.busy == .auth,
                isDisabled: model.busy != nil,
                action: { Task { await model.saveAuth(for: source) } }
            )

            if hasAnyKey {
                SettingsActionButton(
                    title: "Delete Key",
                    isSecondary: true,
                    isDanger: true,
                    isDisabled: model.busy != nil,
                    action: { Task { await model.clearAuth(for: source) } }
                )
            }
        } header: {
            Text("Account & API")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                SettingsHint(text: "Keys are saved on this device. Each source needs its own key. Refresh your feed after saving.")

                if model.isAuthSaved(for: source) {
                    SettingsStatusText(
                        text: "Saved — \(isRule34 ? "Rule34" : "Gelbooru") requests use your key"
                    )
                }
            }
        }
    }

    private var accountURLString: String {
        source == .rule34
            ? "https://rule34.xxx/index.php?page=account&s=options"
            : "https://gelbooru.com/index.php?page=account&s=options"
    }

    private var websiteURLString: String {
        source == .rule34 ? "https://rule34.xxx" : entry.baseURL
    }

    private func openWebsite() {
        guard let url = URL(string: websiteURLString) else { return }
        openURL(url)
    }

    private static func description(for source: SourceID) -> String {
        switch source {
        case .gelbooru: return "The premier anime & artwork imageboard"
        case .yandere: return "High resolution anime scans & art"
        case .danbooru: return "The largest anime imageboard (Requires DNS/VPN in some regions)"
        case .realbooru: return "Real & cosplay booru media"
        case .rule34: return "Community anime & illustration board"
        case .cumst: return "Creator media & clips archive"
        case .redgifs: return "High quality video clips & GIFs"
        case .xvideos: return "Popular video platform search (with preview clips)"
        case .xhamster: return "Popular video platform search (with preview clips)"
        case .pornhub: return "Popular video platform search (official Webmasters API)"
        case .sexcom: return "Popular video platform search (with preview clips)"
        case .hentaihaven: return "Hentai series (official v1 API + episode streaming)"
        case .nhentai: return "Manga and doujinshi archive (official v2 API)"
        }
    }
}

// MARK: - Appearance & playback

/// Image quality picker plus the video-preview switch (RN `renderAppearance`).
struct AppearanceSettingsView: View {
    let model: SettingsViewModel

    private var selectedOption: SettingsViewModel.QualityOption? {
        SettingsViewModel.qualityOptions.first { $0.id == model.settings.imageQuality }
    }

    var body: some View {
        Form {
            Section {
                Picker("Quality", selection: qualityBinding) {
                    ForEach(SettingsViewModel.qualityOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .disabled(model.busy != nil)
            } header: {
                Text("Image quality")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let selectedOption {
                        SettingsHint(text: selectedOption.description)
                    }
                    SettingsHint(text: "Applies to images in the viewer. Original files can use considerably more data.")
                }
            }

            Section {
                SettingsToggleRow(
                    title: "Video previews",
                    subtitle: model.settings.gridPreviews
                        ? "Play previews on visible cards"
                        : "Show static covers only",
                    systemImage: "photo",
                    isOn: model.settings.gridPreviews,
                    isBusy: model.busy == .previews,
                    onChange: { value in Task { await model.setGridPreviews(value) } }
                )
            } header: {
                Text("Motion")
            } footer: {
                SettingsHint(text: "Turn off previews for quieter browsing, less data usage and fewer active video players.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Viewing")
        .navigationBarTitleDisplayMode(.inline)
        .settingsAlert(model)
    }

    /// `setImageQuality` persists and rolls back on failure, so the draft write is async only.
    private var qualityBinding: Binding<ImageQuality> {
        Binding(
            get: { model.settings.imageQuality },
            set: { value in Task { await model.setImageQuality(value) } }
        )
    }
}

// MARK: - Blocked tags

/// Tag editor for the blacklist (RN privacy page plus manual entry).
struct BlacklistSettingsView: View {
    let model: SettingsViewModel

    @State private var isConfirmingClear = false

    init(model: SettingsViewModel) {
        self.model = model
    }

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.item) {
                    TextField("Add a tag to block...", text: $model.newBlacklistTag)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { submitTag() }
                        .accessibilityLabel("New blocked tag")

                    Button {
                        submitTag()
                    } label: {
                        Text("Block")
                            // The 44 pt target is *inside* the label, so the button's own hit
                            // shape reaches 44 x 44. An outer `.frame` would only widen the
                            // HStack slot while the tappable label stayed text-sized.
                            .frame(
                                minWidth: AppTheme.Spacing.minimumHitTarget,
                                minHeight: AppTheme.Spacing.minimumHitTarget
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        model.busy == .tag
                            || model.newBlacklistTag.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }

                if model.blacklistedTags.isEmpty {
                    HStack(spacing: AppTheme.Spacing.item) {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(AppTheme.textMuted)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nothing blocked")
                                .font(AppTheme.Typography.body)
                                .foregroundStyle(AppTheme.textPrimary)
                            Text("Your blocked tags will appear here.")
                                .font(AppTheme.Typography.secondary)
                                .foregroundStyle(AppTheme.textSecondary)
                        }

                        Spacer(minLength: 0)
                    }
                } else {
                    ForEach(model.blacklistedTags, id: \.self) { tag in
                        tagRow(tag)
                    }
                }
            } header: {
                Text("Blocked tags — \(model.blacklistedTags.count)")
            } footer: {
                SettingsHint(text: "Posts with these tags are hidden from feeds and search. Tags are normalized to lowercase with underscores between words.")
            }

            if !model.blacklistedTags.isEmpty {
                Section("Cleanup") {
                    Button("Clear blocked tags", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .disabled(model.busy == .tag)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Blacklist")
        .navigationBarTitleDisplayMode(.inline)
        .settingsAlert(model)
        .task { await model.refreshBlacklist() }
        .confirmationDialog(
            "Clear blocked tags?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await model.clearBlacklistedTags() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Posts with these tags will no longer be hidden.")
        }
    }

    /// One blocked tag: the tag name plus a native destructive remove control.
    private func tagRow(_ tag: String) -> some View {
        HStack(spacing: AppTheme.Spacing.item) {
            Text(tag)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Button {
                Task { await model.removeBlacklistedTag(tag) }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: AppTheme.Icon.standard))
                    .foregroundStyle(AppTheme.danger)
                    .frame(
                        minWidth: AppTheme.Spacing.minimumHitTarget,
                        minHeight: AppTheme.Spacing.minimumHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Unblock \(tag)")
        }
    }

    private func submitTag() {
        Task { await model.addBlacklistedTag() }
    }
}

// MARK: - App lock & privacy

/// PIN, biometrics, and auto-lock controls (RN `renderPrivacy`).
struct AppLockSettingsView: View {
    let model: SettingsViewModel

    @State private var passcodeMode: PasscodeMode?

    init(model: SettingsViewModel) {
        self.model = model
    }

    var body: some View {
        Form {
            Section {
                SettingsToggleRow(
                    title: "Passcode lock",
                    subtitle: model.passcodeEnabled ? "PIN protection enabled" : "Not enabled",
                    systemImage: "lock",
                    isOn: model.passcodeEnabled,
                    isBusy: model.busy == .passcode,
                    onChange: { enabled in
                        passcodeMode = enabled ? .setup : .disable
                    }
                )

                if model.passcodeEnabled {
                    if model.hasBiometrics {
                        SettingsToggleRow(
                            title: "Unlock with biometrics",
                            subtitle: "Your PIN remains available as a fallback",
                            isOn: model.settings.security.useBiometrics,
                            isBusy: model.busy == .biometrics,
                            onChange: { value in Task { await model.setUseBiometrics(value) } }
                        )
                    }

                    SettingsToggleRow(
                        title: "Lock when app leaves foreground",
                        subtitle: "Requires the PIN again after switching apps",
                        isOn: model.settings.security.autoLockImmediately,
                        isBusy: model.busy == .passcode,
                        onChange: { value in Task { await model.setAutoLockImmediately(value) } }
                    )

                    Button {
                        passcodeMode = .change
                    } label: {
                        SettingsRow(
                            title: "Change passcode",
                            subtitle: "Verify the current PIN, then set a new one"
                        )
                    }
                }
            } header: {
                Text("App lock")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsHint(text: "Control access to the app and what appears in your feed. A four-digit PIN protects the app when you open it or return from the background.")
                    SettingsHint(text: "The PIN is stored as a salted hash in the Keychain. Only the hash leaves the settings document, and only as a migration placeholder.")
                }
            }

            Section("Blocked tags") {
                NavigationLink {
                    BlacklistSettingsView(model: model)
                } label: {
                    SettingsRow(
                        title: "Blocked tags",
                        subtitle: model.blacklistedTags.isEmpty
                            ? "Nothing blocked yet"
                            : "\(model.blacklistedTags.count) hidden tag\(model.blacklistedTags.count == 1 ? "" : "s")",
                        systemImage: "eye.slash"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Privacy & safety")
        .navigationBarTitleDisplayMode(.inline)
        .settingsAlert(model)
        .sheet(item: $passcodeMode) { mode in
            PasscodeModalView(
                mode: mode,
                verify: { model.verifyPIN($0) },
                setPasscode: { pin in try await model.setPasscode(pin) },
                clearPasscode: { try await model.disablePasscode() },
                onSuccess: {}
            )
        }
    }
}

// MARK: - Backup & restore

/// Export / import page wired to `fileExporter` and `fileImporter`.
struct BackupSettingsView: View {
    let model: SettingsViewModel

    @State private var isConfirmingCacheClear = false
    @State private var isConfirmingHistoryClear = false

    init(model: SettingsViewModel) {
        self.model = model
    }

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Button {
                    model.isImporting = true
                } label: {
                    SettingsRow(
                        title: "Import backup",
                        subtitle: "Choose an .abbj or JSON file",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .disabled(model.busy == .importBackup)

                Button {
                    Task { await model.prepareExport() }
                } label: {
                    SettingsRow(
                        title: "Export library",
                        subtitle: "Save a JSON backup of favorites, tags and history",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .disabled(model.busy == .exportBackup)
            } header: {
                Text("Backup & transfer")
            } footer: {
                SettingsHint(text: "Supports AnimeBoxes (.abbj) and JSON files. Export your favorites and tags before moving to another device. Imports always merge: existing favorites are kept and favorites, tags and history are deduplicated.")
            }

            Section {
                Button {
                    isConfirmingCacheClear = true
                } label: {
                    SettingsRow(
                        title: "Clear media cache",
                        subtitle: "Thumbnails & temporary post data",
                        systemImage: "externaldrive"
                    )
                }

                Button {
                    isConfirmingHistoryClear = true
                } label: {
                    SettingsRow(
                        title: "Clear search history",
                        subtitle: "Remove searches saved on this device",
                        systemImage: "trash",
                        isDanger: true
                    )
                }
            } header: {
                Text("Free up space")
            } footer: {
                SettingsHint(text: "These actions do not delete your favorites, API keys or preferences.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Storage & backup")
        .navigationBarTitleDisplayMode(.inline)
        .settingsAlert(model)
        .fileExporter(
            isPresented: $model.isExporting,
            document: model.exportDocument,
            contentType: .json,
            defaultFilename: model.exportFileName,
            onCompletion: { result in model.finishExport(result) }
        )
        .fileImporter(
            isPresented: $model.isImporting,
            allowedContentTypes: BackupFileDocument.allowedImportTypes,
            onCompletion: { result in
                Task { await model.handleImport(result) }
            }
        )
        .confirmationDialog(
            "Clear search history?",
            isPresented: $isConfirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await model.clearSearchHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your favorites and blocked tags will be kept.")
        }
        .confirmationDialog(
            "Clear media cache?",
            isPresented: $isConfirmingCacheClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                model.clearCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded thumbnails and temporary post data will be removed. Your favorites and settings will be kept.")
        }
    }
}

// MARK: - Network & proxy relay

/// Cloudflare Worker settings plus the direct/relay diagnostics rows (RN `renderNetwork`).
struct NetworkSettingsView: View {
    let model: SettingsViewModel

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.item) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: AppTheme.Icon.standard, weight: .semibold))
                        .foregroundStyle(AppTheme.primary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.networkSummary)
                            .font(AppTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Applies to all sources")
                            .font(AppTheme.Typography.secondary)
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    Spacer(minLength: 0)
                }
            }

            Section {
                SettingsToggleRow(
                    title: "Route all traffic via Worker",
                    subtitle: model.settings.proxy.enabled
                        ? "Relay enabled for all requests"
                        : "Direct first, with registered Worker fallback",
                    isOn: model.settings.proxy.enabled,
                    isBusy: model.busy == .proxy,
                    onChange: { value in Task { await model.setProxyEnabled(value) } }
                )

                SettingsField(
                    label: "Worker URL",
                    placeholder: "https://your-worker.workers.dev",
                    text: $model.workerURLDraft,
                    isURL: true
                )

                SettingsActionButton(
                    title: "Save URL",
                    isBusy: model.busy == .worker,
                    isDisabled: model.busy != nil || model.isTestingConnection,
                    action: { Task { await model.saveWorkerURL() } }
                )

                if !model.savedWorkerURL.isEmpty {
                    SettingsActionButton(
                        title: "Remove Worker",
                        isSecondary: true,
                        isDanger: true,
                        isDisabled: model.busy != nil || model.isTestingConnection,
                        action: { Task { await model.removeWorker() } }
                    )
                }
            } header: {
                Text("Cloudflare relay")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsHint(text: "With the relay off, a saved Worker is still used for TLS-fragile CDNs and request fallbacks. Remove it to use direct connections only.")

                    if !model.savedWorkerURL.isEmpty, trimmedDraft == model.savedWorkerURL {
                        SettingsStatusText(text: "Worker URL saved on this device")
                    }
                }
            }

            Section {
                Button {
                    Task { await model.testConnection() }
                } label: {
                    SettingsRow(
                        title: "Test connection",
                        systemImage: "waveform.path.ecg"
                    )
                }
                .disabled(model.savedWorkerURL.isEmpty || model.busy != nil || model.isTestingConnection)

                if model.isTestingConnection {
                    HStack(spacing: AppTheme.Spacing.item) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing direct and relay access…")
                            .font(AppTheme.Typography.secondary)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }

                ForEach(model.connectionRows) { row in
                    LabeledContent(row.name) {
                        HStack(spacing: AppTheme.Spacing.item) {
                            resultCell("Direct", row.direct)
                            resultCell("Relay", row.relay)
                        }
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                SettingsHint(text: "Check which sources can be reached on your current connection. Compares direct and relay access; tests do not send your API keys.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .settingsAlert(model)
    }

    /// One diagnostics cell: the leg name (Direct/Relay) above its status.
    private func resultCell(_ label: String, _ result: NetworkDiagnosticResult?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.textMuted)
            Text(Self.statusLabel(result))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Self.statusColor(result))
        }
        .frame(minWidth: 62, alignment: .trailing)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private static func statusLabel(_ result: NetworkDiagnosticResult?) -> String {
        guard let result else { return "—" }
        guard result.reachable else { return "Blocked" }
        if let latency = result.latencyMs {
            return "\(latency) ms"
        }
        return "OK"
    }

    private static func statusColor(_ result: NetworkDiagnosticResult?) -> Color {
        guard let result, result.reachable else { return AppTheme.danger }
        return AppTheme.success
    }

    private var trimmedDraft: String {
        var value = model.workerURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

// MARK: - About

/// Application info plus the 18+ disclaimer (RN About page).
struct AboutSettingsView: View {
    let model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: AppTheme.Spacing.item) {
                    Image(systemName: "square.stack.3d.up")
                        .font(AppTheme.Typography.screenTitle)
                        .foregroundStyle(AppTheme.primaryLight)
                        .accessibilityHidden(true)

                    Text("Booru Viewer")
                        .font(AppTheme.Typography.screenTitle)
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("Your library. Your way.")
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.item)
            }

            Section {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Platform", value: "SwiftUI • iOS 26+")
                LabeledContent("Connection", value: model.networkSummary)
            } header: {
                Text("Application")
            } footer: {
                SettingsHint(text: "An independent multi-source viewer. Not affiliated with any content source. Adults only (18+).")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .settingsAlert(model)
    }
}
