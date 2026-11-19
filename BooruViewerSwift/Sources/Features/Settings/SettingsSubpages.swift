import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared building blocks

/// Presents `SettingsViewModel.alert` from whichever settings page is on screen.
private struct SettingsAlertModifier: ViewModifier {
    let model: SettingsViewModel

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.alert(item: $model.alert) { state in
            Alert(
                title: Text(state.title),
                message: Text(state.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

extension View {
    /// Attaches the settings alert to a subpage.
    func settingsAlert(_ model: SettingsViewModel) -> some View {
        modifier(SettingsAlertModifier(model: model))
    }
}


/// Short page introduction, matching the RN `pageIntro` style.
struct SettingsPageIntro: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTheme.Typography.body)
            .foregroundStyle(AppTheme.color(0xA1A6BB))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Uppercase caption above a grouped card (RN `SettingsSection`).
struct SettingsSection<Content: View>: View {
    let title: String
    var hint: String?
    let content: Content

    init(title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
            Text(title.uppercased())
                .font(AppTheme.Typography.caption)
                .kerning(1.4)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content
            }
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppTheme.border, lineWidth: 1)
            )

            if let hint {
                SettingsHint(text: hint)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Muted helper copy shown under a section or a form.
struct SettingsHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTheme.Typography.secondary)
            .foregroundStyle(AppTheme.textSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tinted info box (RN `ui.note`).
struct SettingsNoteBox<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.primary.opacity(0.15), lineWidth: 1)
            )
    }
}

/// Green confirmation line (RN `ui.status`).
struct SettingsStatusText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTheme.Typography.secondary)
            .foregroundStyle(AppTheme.color(0x82CDB1))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One grouped row: optional icon, title/subtitle, value, chevron, spinner.
struct SettingsRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var value: String? = nil
    var isDanger = false
    var isLast = false
    var isBusy = false
    var showsDisclosure = false
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            } else {
                rowContent
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(AppTheme.divider)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: AppTheme.Spacing.item) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.Icon.small, weight: .semibold))
                    .foregroundStyle(isDanger ? AppTheme.danger : AppTheme.primaryLight)
                    .frame(width: 28, height: 28)
                    .background(
                        isDanger ? AppTheme.danger.opacity(0.06) : AppTheme.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(isDanger ? AppTheme.color(0xF28B94) : AppTheme.color(0xECEEF5))
                if let subtitle {
                    Text(subtitle)
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AppTheme.Spacing.item)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppTheme.primaryLight)
            } else {
                if let value {
                    Text(value)
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                if action != nil || showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textMuted)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppTheme.Spacing.rowVertical)
        .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
        .contentShape(Rectangle())
    }
}

/// Grouped row with a switch.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    let isOn: Bool
    var isLast = false
    var isBusy = false
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.item) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.Icon.small, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryLight)
                    .frame(width: 28, height: 28)
                    .background(AppTheme.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(AppTheme.color(0xECEEF5))
                if let subtitle {
                    Text(subtitle)
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AppTheme.Spacing.item)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppTheme.primaryLight)
            } else {
                Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                    .labelsHidden()
                    .tint(AppTheme.primary)
                    .accessibilityLabel(title)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppTheme.Spacing.rowVertical)
        .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(AppTheme.divider)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}

/// Primary / secondary / destructive action button (RN `SettingsButton`).
struct SettingsActionButton: View {
    let title: String
    var isSecondary = false
    var isDanger = false
    var isBusy = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.textPrimary)
                } else {
                    Text(title)
                        .font(AppTheme.Typography.body)
                        .fontWeight(.semibold)
                }
            }
            .foregroundStyle(isDanger ? AppTheme.color(0xF28B94) : AppTheme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: AppTheme.Spacing.minimumHitTarget)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isBusy)
        .opacity(isDisabled || isBusy ? 0.5 : 1)
    }

    private var background: Color {
        if isDanger {
            return AppTheme.danger.opacity(0.08)
        }
        return isSecondary ? AppTheme.color(0x282D40) : AppTheme.primary
    }
}

/// Labeled text field used inside forms.
struct SettingsField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var isSecure = false
    var isNumeric = false
    var isURL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(AppTheme.Typography.secondary)
                .fontWeight(.semibold)
                .foregroundStyle(AppTheme.color(0xC0C3D0))

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(AppTheme.Typography.body)
            .foregroundStyle(AppTheme.textPrimary)
            .tint(AppTheme.primaryLight)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(isNumeric ? .numberPad : (isURL ? .URL : .default))
            .padding(.horizontal, 12)
            .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
            .background(AppTheme.color(0x10121B), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AppTheme.color(0x2A2E40), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}

// MARK: - Sources

/// Source picker plus a per-source settings entry, mirroring the RN sources page.
struct SourcesSettingsView: View {
    let model: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                SettingsPageIntro(text: "Switch with a tap. Use the settings icon for account & API options.")

                SettingsSection(title: "All sources") {
                    ForEach(entries) { entry in
                        sourceRow(entry, isLast: entry.id == entries.last?.id)
                    }
                }

                SettingsHint(text: "Keys are saved on this device only. Each source needs its own key.")
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            .padding(.vertical, AppTheme.Spacing.section)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Sources & API Keys")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var entries: [SourceSheetView.Entry] {
        SourceSheetView.visibleCatalog
    }

    private func sourceRow(_ entry: SourceSheetView.Entry, isLast: Bool) -> some View {
        let isActive = entry.id == model.activeSourceID

        return HStack(spacing: AppTheme.Spacing.item) {
            Button {
                Task { await model.selectSource(entry.id) }
            } label: {
                HStack(spacing: AppTheme.Spacing.item) {
                    SourceMarkBadge(entry: entry, size: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(AppTheme.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(AppTheme.textPrimary)
                            if isActive {
                                Text("ACTIVE")
                                    .font(.system(.caption2, weight: .heavy))
                                    .kerning(0.7)
                                    .foregroundStyle(AppTheme.primaryLight)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        AppTheme.primary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 4)
                                    )
                            }
                        }
                        Text("\(entry.kind) • \(entry.host)")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                // The source row paints at 34 pt; the 44 pt frame is the row's own tap lane.
                .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy == .source)

            NavigationLink {
                SourceDetailSettingsView(source: entry.id, model: model)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: AppTheme.Icon.small, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                    // Real layout, not a painted overlay: the gear owns a 44 pt target while the
                    // 28 pt badge above stays visually compact.
                    .frame(
                        minWidth: AppTheme.Spacing.minimumHitTarget,
                        minHeight: AppTheme.Spacing.minimumHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.name) settings")
        }
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(AppTheme.divider)
                    .frame(height: 1)
                    .padding(.leading, 56)
            }
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
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                hero

                if KeychainStore.authAccount(for: source) != nil {
                    authSection
                } else {
                    SettingsNoteBox {
                        SettingsHint(text: "No manual API key is needed for this source. Connection preferences apply across all sources.")
                    }
                }

                SettingsSection(title: "Source details") {
                    SettingsRow(
                        title: "Website",
                        subtitle: entry.host,
                        systemImage: "globe",
                        showsDisclosure: true,
                        action: { openWebsite() }
                    )
                    NavigationLink {
                        NetworkSettingsView(model: model)
                    } label: {
                        SettingsRow(
                            title: "Connection settings",
                            subtitle: "App-wide relay & connection diagnostics",
                            systemImage: "antenna.radiowaves.left.and.right",
                            isLast: true,
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            .padding(.vertical, AppTheme.Spacing.section)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }

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
                .foregroundStyle(AppTheme.color(0x9CA1B8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            if isActive {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Your current source")
                        .font(AppTheme.Typography.secondary)
                }
                .foregroundStyle(AppTheme.color(0xA6ACFF))
                .padding(.vertical, 6)
            } else {
                SettingsActionButton(
                    title: "Use \(entry.name)",
                    isBusy: model.busy == .source,
                    action: { Task { await model.selectSource(source) } }
                )
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var authSection: some View {
        let isRule34 = source == .rule34

        return SettingsSection(
            title: "Account & API",
            hint: "Keys are saved on this device. Each source needs its own key. Refresh your feed after saving."
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                HStack(spacing: AppTheme.Spacing.item) {
                    Image(systemName: "key")
                        .font(.system(size: AppTheme.Icon.standard, weight: .semibold))
                        .foregroundStyle(AppTheme.color(0xA0A7F5))
                    Text(isRule34 ? "API key required" : "Connect your account")
                        .font(AppTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.color(0xE5E7F0))
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
                                .font(AppTheme.Typography.secondary)
                                .fontWeight(.medium)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(AppTheme.color(0xA6ACFF))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                }

                ApiAuthForm(model: model, source: source)
            }
            .padding(14)
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

/// Credentials editor for the two sources that support API auth.
private struct ApiAuthForm: View {
    let model: SettingsViewModel
    let source: SourceID

    var body: some View {
        @Bindable var model = model
        let isRule34 = source == .rule34
        let saved = model.savedAuth(for: source)

        VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
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

            HStack(spacing: AppTheme.Spacing.item) {
                SettingsActionButton(
                    title: "Save",
                    isBusy: model.busy == .auth,
                    isDisabled: model.busy != nil,
                    action: { Task { await model.saveAuth(for: source) } }
                )

                let hasAnyKey = !model.auth(for: source).apiKey.isEmpty
                    || !model.auth(for: source).userID.isEmpty
                    || !saved.apiKey.isEmpty
                if hasAnyKey {
                    SettingsActionButton(
                        title: "Delete Key",
                        isSecondary: true,
                        isDanger: true,
                        isDisabled: model.busy != nil,
                        action: { Task { await model.clearAuth(for: source) } }
                    )
                }
            }

            if model.isAuthSaved(for: source) {
                SettingsStatusText(
                    text: "Saved — \(isRule34 ? "Rule34" : "Gelbooru") requests use your key"
                )
            }
        }
    }
}

// MARK: - Appearance & playback

/// Image quality radios plus the video-preview switch (RN `renderAppearance`).
struct AppearanceSettingsView: View {
    let model: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                SettingsPageIntro(text: "Image quality and motion preferences.")

                SettingsSection(
                    title: "Image quality",
                    hint: "Applies to images in the viewer. Original files can use considerably more data."
                ) {
                    let options = SettingsViewModel.qualityOptions
                    ForEach(options) { option in
                        QualityChoiceRow(
                            option: option,
                            isSelected: model.settings.imageQuality == option.id,
                            isDisabled: model.busy != nil,
                            isLast: option.id == options.last?.id,
                            action: { Task { await model.setImageQuality(option.id) } }
                        )
                    }
                }

                SettingsSection(
                    title: "Motion",
                    hint: "Turn off previews for quieter browsing, less data usage and fewer active video players."
                ) {
                    SettingsToggleRow(
                        title: "Video previews",
                        subtitle: model.settings.gridPreviews
                            ? "Play previews on visible cards"
                            : "Show static covers only",
                        systemImage: "photo",
                        isOn: model.settings.gridPreviews,
                        isLast: true,
                        isBusy: model.busy == .previews,
                        onChange: { value in Task { await model.setGridPreviews(value) } }
                    )
                }
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            .padding(.vertical, AppTheme.Spacing.section)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Viewing")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct QualityChoiceRow: View {
    let option: SettingsViewModel.QualityOption
    let isSelected: Bool
    let isDisabled: Bool
    let isLast: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.item) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.name)
                            .font(AppTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(AppTheme.color(0xE5E7F0))
                        if option.id == .auto {
                            Text("RECOMMENDED")
                                .font(.system(.caption2, weight: .bold))
                                .kerning(0.5)
                                .foregroundStyle(AppTheme.color(0xA5ABEA))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    AppTheme.primary.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                        }
                    }
                    Text(option.description)
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.color(0x959BB2))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: AppTheme.Spacing.item)

                ZStack {
                    Circle()
                        .stroke(
                            isSelected ? AppTheme.primary : AppTheme.color(0x363C52),
                            lineWidth: 1.5
                        )
                        .frame(width: 19, height: 19)
                    if isSelected {
                        Circle()
                            .fill(AppTheme.primary)
                            .frame(width: 19, height: 19)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, AppTheme.Spacing.rowVertical)
            .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(AppTheme.divider)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}

// MARK: - Blocked tags

/// Tag editor for the blacklist (RN privacy page tag chips plus manual entry).
struct BlacklistSettingsView: View {
    let model: SettingsViewModel

    @State private var isConfirmingClear = false

    init(model: SettingsViewModel) {
        self.model = model
    }

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                SettingsPageIntro(text: "Posts with these tags are hidden from feeds and search.")

                SettingsSection(
                    title: "Blocked tags — \(model.blacklistedTags.count)",
                    hint: "Tags are normalized to lowercase with underscores between words."
                ) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                        HStack(spacing: AppTheme.Spacing.item) {
                            TextField("Add a tag to block...", text: $model.newBlacklistTag)
                                .font(AppTheme.Typography.body)
                                .foregroundStyle(AppTheme.textPrimary)
                                .tint(AppTheme.primaryLight)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .onSubmit { submitTag() }
                                .padding(.horizontal, 12)
                                .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
                                .background(
                                    AppTheme.color(0x10121B),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(AppTheme.color(0x2A2E40), lineWidth: 1)
                                )

                            SettingsActionButton(
                                title: "Block",
                                isBusy: model.busy == .tag,
                                isDisabled: model.newBlacklistTag.trimmingCharacters(in: .whitespaces).isEmpty,
                                action: { submitTag() }
                            )
                            .frame(width: 88)
                        }

                        if model.blacklistedTags.isEmpty {
                            HStack(spacing: AppTheme.Spacing.item) {
                                Image(systemName: "eye.slash")
                                    .font(.system(size: AppTheme.Icon.standard))
                                    .foregroundStyle(AppTheme.textMuted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Nothing blocked")
                                        .font(AppTheme.Typography.body)
                                        .fontWeight(.medium)
                                        .foregroundStyle(AppTheme.color(0xD9DCE9))
                                    Text("Your blocked tags will appear here.")
                                        .font(AppTheme.Typography.secondary)
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                            }
                            .padding(.vertical, 6)
                        } else {
                            FlexibleTagFlow(tags: model.blacklistedTags) { tag in
                                Task { await model.removeBlacklistedTag(tag) }
                            }
                        }
                    }
                    .padding(12)
                }

                if !model.blacklistedTags.isEmpty {
                    SettingsSection(title: "Cleanup") {
                        SettingsRow(
                            title: "Clear blocked tags",
                            subtitle: "Posts with these tags will no longer be hidden",
                            systemImage: "trash",
                            isDanger: true,
                            isLast: true,
                            isBusy: model.busy == .tag,
                            action: { isConfirmingClear = true }
                        )
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            .padding(.vertical, AppTheme.Spacing.section)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Blacklist")
        .navigationBarTitleDisplayMode(.inline)
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

    private func submitTag() {
        Task { await model.addBlacklistedTag() }
    }
}

/// Wrapping tag chips with a remove control; keeps the RN chip look.
private struct FlexibleTagFlow: View {
    let tags: [String]
    let onRemove: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: AppTheme.Spacing.item)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.item) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 2) {
                    Text(tag)
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.color(0xD2D6E7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button {
                        onRemove(tag)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppTheme.color(0xC5C8D5))
                            // The remove control now spends real layout on a 44 x 44 target.
                            // Only the pill's background is inset vertically, so the painted
                            // chip stays compact while the tap area is fully allocated.
                            .frame(
                                minWidth: AppTheme.Spacing.minimumHitTarget,
                                minHeight: AppTheme.Spacing.minimumHitTarget
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unblock \(tag)")
                }
                .padding(.leading, AppTheme.Spacing.chipHorizontal)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(AppTheme.color(0x252A3C))
                        .padding(.vertical, 5)
                )
            }
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                SettingsPageIntro(text: "Control access to the app and what appears in your feed.")

                SettingsSection(
                    title: "App lock",
                    hint: "A four-digit PIN protects the app when you open it or return from the background."
                ) {
                    SettingsToggleRow(
                        title: "Passcode lock",
                        subtitle: model.passcodeEnabled ? "PIN protection enabled" : "Not enabled",
                        systemImage: "lock",
                        isOn: model.passcodeEnabled,
                        isLast: !model.passcodeEnabled,
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

                        SettingsRow(
                            title: "Change passcode",
                            subtitle: "Verify the current PIN, then set a new one",
                            isLast: true,
                            showsDisclosure: true,
                            action: { passcodeMode = .change }
                        )
                    }
                }

                SettingsSection(title: "Blocked tags") {
                    NavigationLink {
                        BlacklistSettingsView(model: model)
                    } label: {
                        SettingsRow(
                            title: "Blocked tags",
                            subtitle: model.blacklistedTags.isEmpty
                                ? "Nothing blocked yet"
                                : "\(model.blacklistedTags.count) hidden tag\(model.blacklistedTags.count == 1 ? "" : "s")",
                            systemImage: "eye.slash",
                            isLast: true,
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)
                }

                SettingsHint(text: "The PIN is stored exclusively as a salted hash in the Keychain and is never written to the settings document.")
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            .padding(.vertical, AppTheme.Spacing.section)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Privacy & safety")
        .navigationBarTitleDisplayMode(.inline)
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

/// Export / import page wired to `fileExporter` and `fileImporter` on the settings screen.
struct BackupSettingsView: View {
    let model: SettingsViewModel

    @State private var isConfirmingCacheClear = false
    @State private var isConfirmingHistoryClear = false

    init(model: SettingsViewModel) {
        self.model = model
    }

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                SettingsPageIntro(text: "Back up your library and manage local data.")

                SettingsSection(
                    title: "Backup & transfer",
                    hint: "Supports AnimeBoxes (.abbj) and JSON files. Export your favorites and tags before moving to another device."
                ) {
                    SettingsRow(
                        title: "Import backup",
                        subtitle: "Choose an .abbj or JSON file",
                        systemImage: "square.and.arrow.down",
                        isBusy: model.busy == .importBackup,
                        action: { model.isImporting = true }
                    )

                    SettingsRow(
                        title: "Export library",
                        subtitle: "Save a JSON backup of favorites, tags and history",
                        systemImage: "square.and.arrow.up",
                        isLast: true,
                        isBusy: model.busy == .exportBackup,
                        action: { Task { await model.prepareExport() } }
                    )
                }

                SettingsSection(
                    title: "Free up space",
                    hint: "These actions do not delete your favorites, API keys or preferences."
                ) {
                    SettingsRow(
                        title: "Clear media cache",
                        subtitle: "Thumbnails & temporary post data",
                        systemImage: "externaldrive",
                        action: { isConfirmingCacheClear = true }
                    )

                    SettingsRow(
                        title: "Clear search history",
                        subtitle: "Remove searches saved on this device",
                        systemImage: "trash",
                        isDanger: true,
                        isLast: true,
                        action: { isConfirmingHistoryClear = true }
                    )
                }

                SettingsNoteBox {
                    SettingsHint(text: "Imports always merge: existing favorites are kept and favorites, tags and history are deduplicated.")
                }
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            .padding(.vertical, AppTheme.Spacing.section)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Storage & backup")
        .navigationBarTitleDisplayMode(.inline)
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

/// Cloudflare Worker settings plus the direct/relay diagnostics table (RN `renderNetwork`).
struct NetworkSettingsView: View {
    let model: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                SettingsPageIntro(text: "Choose how you connect.")

                connectionBanner

                SettingsSection(
                    title: "Cloudflare relay",
                    hint: "With the relay off, a saved Worker is still used for TLS-fragile CDNs and request fallbacks. Remove it to use direct connections only."
                ) {
                    SettingsToggleRow(
                        title: "Route all traffic via Worker",
                        subtitle: model.settings.proxy.enabled
                            ? "Relay enabled for all requests"
                            : "Direct first, with registered Worker fallback",
                        isOn: model.settings.proxy.enabled,
                        isBusy: model.busy == .proxy,
                        onChange: { value in Task { await model.setProxyEnabled(value) } }
                    )

                    workerForm
                }

                diagnosticsSection
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            .padding(.vertical, AppTheme.Spacing.section)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var connectionBanner: some View {
        HStack(spacing: AppTheme.Spacing.item) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: AppTheme.Icon.standard, weight: .semibold))
                .foregroundStyle(AppTheme.color(0xA0A7F5))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.networkSummary)
                    .font(AppTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.color(0xE5E7F0))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Applies to all sources")
                    .font(AppTheme.Typography.secondary)
                    .foregroundStyle(AppTheme.color(0x959BB2))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AppTheme.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var workerForm: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
            SettingsField(
                label: "Worker URL",
                placeholder: "https://your-worker.workers.dev",
                text: $model.workerURLDraft,
                isURL: true
            )

            HStack(spacing: AppTheme.Spacing.item) {
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
            }

            if !model.savedWorkerURL.isEmpty {
                if trimmedDraft == model.savedWorkerURL {
                    SettingsStatusText(text: "Worker URL saved on this device")
                }
            }
        }
        .padding(14)
    }

    private var diagnosticsSection: some View {
        SettingsSection(
            title: "Diagnostics",
            hint: "Compares direct and relay access. Tests do not send your API keys."
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                SettingsHint(text: "Check which sources can be reached on your current connection.")

                SettingsActionButton(
                    title: "Test connection",
                    isSecondary: true,
                    isBusy: model.isTestingConnection,
                    isDisabled: model.savedWorkerURL.isEmpty || model.busy != nil,
                    action: { Task { await model.testConnection() } }
                )

                if !model.connectionRows.isEmpty {
                    resultsTable
                }
            }
            .padding(14)
        }
    }

    private var resultsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("SOURCE")
                    .font(.system(.caption2, weight: .bold))
                    .kerning(0.7)
                    .foregroundStyle(AppTheme.color(0x747B96))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("DIRECT")
                    .font(.system(.caption2, weight: .bold))
                    .kerning(0.7)
                    .foregroundStyle(AppTheme.color(0x747B96))
                    .frame(width: 76, alignment: .trailing)
                Text("RELAY")
                    .font(.system(.caption2, weight: .bold))
                    .kerning(0.7)
                    .foregroundStyle(AppTheme.color(0x747B96))
                    .frame(width: 76, alignment: .trailing)
            }
            .padding(.vertical, AppTheme.Spacing.rowVertical)

            ForEach(model.connectionRows) { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.color(0xC2C6D9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    resultCell(row.direct)
                    resultCell(row.relay)
                }
                .padding(.vertical, AppTheme.Spacing.rowVertical)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(AppTheme.divider)
                        .frame(height: 1)
                }
            }
        }
    }

    private func resultCell(_ result: NetworkDiagnosticResult?) -> some View {
        Text(Self.statusLabel(result))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Self.statusColor(result))
            .frame(width: 76, alignment: .trailing)
            .lineLimit(1)
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
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                VStack(spacing: AppTheme.Spacing.item) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(AppTheme.color(0xB1B5FF))
                        .frame(width: 64, height: 64)
                        .background(AppTheme.color(0x1B1E39), in: RoundedRectangle(cornerRadius: 20))
                    Text("Booru Viewer")
                        .font(AppTheme.Typography.screenTitle)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Your library. Your way.")
                        .font(AppTheme.Typography.secondary)
                        .foregroundStyle(AppTheme.color(0x969BB3))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)

                SettingsSection(title: "Application") {
                    SettingsRow(title: "Version", value: "1.0.0")
                    SettingsRow(title: "Platform", value: "SwiftUI • iOS 17+")
                    SettingsRow(title: "Connection", value: model.networkSummary, isLast: true)
                }

                SettingsHint(text: "An independent multi-source viewer. Not affiliated with any content source. Adults only (18+).")
            }
            .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
            .padding(.vertical, AppTheme.Spacing.section)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
