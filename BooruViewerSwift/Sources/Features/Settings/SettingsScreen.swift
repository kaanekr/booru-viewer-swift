import SwiftUI

/// Settings tab home.
///
/// Presentation is stock iOS 26: a `Form` (inset-grouped `List`) of native `Section`s,
/// `NavigationLink` rows, and section headers/footers. The system owns the card fills,
/// separators, row heights, and the navigation bar's Liquid Glass; nothing here paints a
/// background, rounded card, or custom divider over them.
///
/// Every subpage is pushed from here, so the screen must live inside a `NavigationStack`
/// (`RootTabView.settingsTab`). The single `SettingsViewModel` stays the owner of every
/// action; this file only wires rows to it.
struct SettingsScreen: View {
    @State private var model: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        _model = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if model.isLoading && !model.hasLoaded {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppTheme.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                settingsForm
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .tint(AppTheme.primary)
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .settingsAlert(model)
    }

    // MARK: - Form

    private var settingsForm: some View {
        Form {
            Section {
                NavigationLink {
                    SourcesSettingsView(model: model)
                } label: {
                    sourceHero
                }
            } header: {
                Text("YOUR SOURCE")
            } footer: {
                Text("Browse & manage sources")
            }

            Section("Your experience") {
                NavigationLink {
                    AppearanceSettingsView(model: model)
                } label: {
                    SettingsRow(
                        title: "Viewing",
                        subtitle: "Image quality & video previews",
                        systemImage: "photo",
                        value: model.imageQualityName
                    )
                }

                NavigationLink {
                    AppLockSettingsView(model: model)
                } label: {
                    SettingsRow(
                        title: "Privacy & safety",
                        subtitle: "App lock, biometrics & blocked tags",
                        systemImage: "shield"
                    )
                }

                NavigationLink {
                    BlacklistSettingsView(model: model)
                } label: {
                    SettingsRow(
                        title: "Blocked tags",
                        subtitle: model.blacklistedTags.isEmpty
                            ? "Nothing blocked"
                            : "\(model.blacklistedTags.count) hidden tag\(model.blacklistedTags.count == 1 ? "" : "s")",
                        systemImage: "eye.slash"
                    )
                }
            }

            Section {
                NavigationLink {
                    NetworkSettingsView(model: model)
                } label: {
                    SettingsRow(
                        title: "Connection",
                        subtitle: "Cloudflare relay & diagnostics",
                        systemImage: "antenna.radiowaves.left.and.right",
                        value: model.networkSummary
                    )
                }

                NavigationLink {
                    BackupSettingsView(model: model)
                } label: {
                    SettingsRow(
                        title: "Storage & backup",
                        subtitle: "Cache, history & your library",
                        systemImage: "externaldrive"
                    )
                }

                NavigationLink {
                    AboutSettingsView(model: model)
                } label: {
                    SettingsRow(
                        title: "About",
                        systemImage: "info.circle",
                        value: "1.0.0"
                    )
                }
            } header: {
                Text("App & data")
            } footer: {
                Text("BOORU VIEWER • Version 1.0.0")
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Active source summary. The brand mark keeps the source identity; the row itself is a
    /// plain `NavigationLink` label so the enclosing `Section` supplies the card and chevron.
    private var sourceHero: some View {
        let entry = SourceSheetView.entry(for: model.activeSourceID)

        return HStack(spacing: AppTheme.Spacing.item) {
            SourceMarkBadge(entry: entry, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(AppTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(entry.kind) • \(entry.host)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AppTheme.Spacing.item)

            Text("Selected")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.primaryLight)
        }
        .frame(minHeight: AppTheme.Spacing.minimumHitTarget)
    }
}
