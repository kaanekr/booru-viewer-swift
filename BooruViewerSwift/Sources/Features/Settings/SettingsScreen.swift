import SwiftUI

/// Settings tab home.
///
/// Mirrors `src/screens/SettingsScreen.tsx`: a source hero, an experience group
/// (viewing, privacy, blocked tags), and an app/data group (connection, storage, about).
/// Every subpage is pushed from here, so the screen must live inside a `NavigationStack`.
struct SettingsScreen: View {
    @State private var model: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        _model = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var model = model

        ZStack {
            AppTheme.background.ignoresSafeArea()

            if model.isLoading && !model.hasLoaded {
                ProgressView()
                    .tint(AppTheme.primaryLight)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        NavigationLink {
                            SourcesSettingsView(model: model)
                        } label: {
                            sourceHero
                        }
                        .buttonStyle(.plain)

                        experienceGroup
                        dataGroup
                        footer
                    }
                    .padding(.horizontal, AppTheme.Spacing.screenHorizontal)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .tint(AppTheme.primary)
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .alert(item: $model.alert) { state in
            Alert(
                title: Text(state.title),
                message: Text(state.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Hero

    private var sourceHero: some View {
        let entry = SourceSheetView.entry(for: model.activeSourceID)

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("YOUR SOURCE")
                    .font(.system(.caption2, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(AppTheme.color(0x9B9FBA))

                Spacer(minLength: AppTheme.Spacing.item)

                HStack(spacing: 5) {
                    Circle()
                        .fill(AppTheme.color(0xA6ACFF))
                        .frame(width: 4, height: 4)
                    Text("Selected")
                        .font(AppTheme.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(AppTheme.color(0xAFB4E3))
                }
                .padding(.horizontal, AppTheme.Spacing.chipHorizontal)
                .padding(.vertical, 3)
                .background(AppTheme.primary.opacity(0.05), in: Capsule())
            }

            HStack(spacing: AppTheme.Spacing.item) {
                SourceMarkBadge(entry: entry, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(AppTheme.Typography.screenTitle)
                        .foregroundStyle(AppTheme.color(0xF2F3FA))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(entry.kind) • \(entry.host)")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.color(0x959AB4))
                        .lineLimit(1)
                }

                Spacer(minLength: AppTheme.Spacing.item)

                Image(systemName: "chevron.right")
                    .font(.system(size: AppTheme.Icon.small, weight: .semibold))
                    .foregroundStyle(AppTheme.color(0x9B9FC0))
            }
            .padding(.top, 12)

            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 11, weight: .semibold))
                Text("Browse & manage sources")
                    .font(AppTheme.Typography.caption)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(AppTheme.color(0x949AC4))
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.035))
                    .frame(height: 1)
            }
            .padding(.top, 14)
        }
        .padding(14)
        .background(AppTheme.color(0x171B2C), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppTheme.color(0x343953), lineWidth: 1)
        )
        .padding(.bottom, 18)
    }

    // MARK: - Groups

    private var experienceGroup: some View {
        SettingsSection(title: "Your experience") {
            NavigationLink {
                AppearanceSettingsView(model: model)
            } label: {
                SettingsRow(
                    title: "Viewing",
                    subtitle: "Image quality & video previews",
                    systemImage: "photo",
                    value: model.imageQualityName,
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                AppLockSettingsView(model: model)
            } label: {
                SettingsRow(
                    title: "Privacy & safety",
                    subtitle: "App lock, biometrics & blocked tags",
                    systemImage: "shield",
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                BlacklistSettingsView(model: model)
            } label: {
                SettingsRow(
                    title: "Blocked tags",
                    subtitle: model.blacklistedTags.isEmpty
                        ? "Nothing blocked"
                        : "\(model.blacklistedTags.count) hidden tag\(model.blacklistedTags.count == 1 ? "" : "s")",
                    systemImage: "eye.slash",
                    isLast: true,
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 18)
    }

    private var dataGroup: some View {
        SettingsSection(title: "App & data") {
            NavigationLink {
                NetworkSettingsView(model: model)
            } label: {
                SettingsRow(
                    title: "Connection",
                    subtitle: model.networkSummary,
                    systemImage: "antenna.radiowaves.left.and.right",
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                BackupSettingsView(model: model)
            } label: {
                SettingsRow(
                    title: "Storage & backup",
                    subtitle: "Cache, history & your library",
                    systemImage: "externaldrive",
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                AboutSettingsView(model: model)
            } label: {
                SettingsRow(
                    title: "About",
                    systemImage: "info.circle",
                    value: "1.0.0",
                    isLast: true,
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 18)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: AppTheme.Spacing.item) {
            HStack(spacing: AppTheme.Spacing.section) {
                Rectangle()
                    .fill(AppTheme.color(0x242839))
                    .frame(height: 1)
                Text("BOORU VIEWER")
                    .font(.system(.caption2, weight: .bold))
                    .kerning(2.0)
                    .foregroundStyle(AppTheme.color(0x656B86))
                Rectangle()
                    .fill(AppTheme.color(0x242839))
                    .frame(height: 1)
            }
            .padding(.horizontal, 22)

            Text("Version 1.0.0")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.color(0x666C82))
        }
        .padding(.top, 4)
    }
}
