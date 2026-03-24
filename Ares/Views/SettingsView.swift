import SwiftUI
import AppKit

struct SettingsView: View {
    @Binding var isPresented: Bool
    @AppStorage("useImperialUnits") private var useImperialUnits = false
    @AppStorage("terrainSourceMode") private var terrainSourceMode = TerrainSource.prebaked.rawValue
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    @State private var showResetAlert = false
    @State private var showSetupAlert = false
    @State private var pickerSelection: TerrainSource = .prebaked
    @State private var showCopied = false

    private let appVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Ares Preview v\(version) (Build \(build))"
    }()

    var body: some View {
        GeometryReader { geo in
            let maxHeight = geo.size.height - 80 // 40pt margin top + bottom

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    Text("Settings")
                        .font(.blender(.medium, size: 24))
                        .foregroundStyle(.primary)

                    Spacer()

                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 24)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 28) {
                        // Units
                        settingsSection(
                            title: "Units",
                            description: "Choose how measurements are displayed across Ares."
                        ) {
                            unitsPicker
                        }

                        settingsSection(
                            title: "Upscaling",
                            description: "Ares can run a local neural network called Ares SR that upscales Mars imagery using your Mac's Neural Engine. This one time process takes ~ 15 minutes."
                        ) {
                            terrainPicker
                            terrainFootnote
                            terrainActions
                        }

                        // Storage
                        settingsSection(
                            title: "Storage",
                            description: "Manage/view locally upscaled imagery."
                        ) {
                            storageSection
                        }

                        // About
                        aboutSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.automatic)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .frame(width: 400)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { pickerSelection = currentTerrainSource }
        }
        .alert("Clear Local Data?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Local Data", role: .destructive) {
                clearLocalRenderedData()
            }
        } message: {
            Text("This will remove any locally upscaled files from your system. The pre-upscaled files shipped with Ares will still be available.")
        }
        .alert("Run Local Setup?", isPresented: $showSetupAlert) {
            Button("Continue") {
                hasCompletedSetup = false
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will take you back to the onboarding screen to locally upscale Mars imagery.")
        }
    }

    // MARK: - Units

    private var unitsPicker: some View {
        HStack(spacing: 0) {
            Button { useImperialUnits = false } label: {
                Text("Metric")
                    .font(.blender(.medium, size: 14))
                    .foregroundStyle(useImperialUnits ? .secondary : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { useImperialUnits = true } label: {
                Text("Imperial")
                    .font(.blender(.medium, size: 14))
                    .foregroundStyle(useImperialUnits ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(3)
        .background(
            GeometryReader { geo in
                let inset: CGFloat = 3
                let indicatorWidth = (geo.size.width - inset * 2 - 2) / 2
                let indicatorHeight = geo.size.height - inset * 2
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(0.08))
                    .frame(width: indicatorWidth, height: indicatorHeight)
                    .offset(
                        x: useImperialUnits ? indicatorWidth + inset + 2 : inset,
                        y: inset
                    )
                    .animation(.easeInOut(duration: 0.2), value: useImperialUnits)
            }
            .allowsHitTesting(false)
        )
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsRow(
                icon: "folder",
                label: "View locally upscaled files",
                detail: TerrainAssetPaths.localRenderedSizeString
            ) {
                showLocalDataInFinder()
            }

            settingsRow(
                icon: "trash",
                label: "Clear locally upscaled files"
            ) {
                showResetAlert = true
            }
        }
    }

    // MARK: - Terrain

    private var terrainPicker: some View {
        HStack(spacing: 0) {
            Button {
                pickerSelection = .prebaked
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    terrainSourceMode = TerrainSource.prebaked.rawValue
                }
            } label: {
                Text("Pre-upscaled")
                    .font(.blender(.medium, size: 14))
                    .foregroundStyle(pickerSelection == .local ? .secondary : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                pickerSelection = .local
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    terrainSourceMode = TerrainSource.local.rawValue
                }
            } label: {
                Text("Run locally")
                    .font(.blender(.medium, size: 14))
                    .foregroundStyle(pickerSelection == .local ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(3)
        .background(
            GeometryReader { geo in
                let inset: CGFloat = 3
                let indicatorWidth = (geo.size.width - inset * 2 - 2) / 2
                let indicatorHeight = geo.size.height - inset * 2
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(0.08))
                    .frame(width: indicatorWidth, height: indicatorHeight)
                    .offset(
                        x: pickerSelection == .local ? indicatorWidth + inset + 2 : inset,
                        y: inset
                    )
                    .animation(.easeInOut(duration: 0.2), value: pickerSelection)
            }
            .allowsHitTesting(false)
        )
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var terrainFootnote: some View {
        Text("Pre-upscaled imagery generated on an M4 MacBook Pro ships with Ares so you can explore immediately with no first-time render.")
            .font(.blender(.book, size: 14))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
    }

    @ViewBuilder
    private var terrainActions: some View {
        if currentTerrainSource == .local && !TerrainAssetPaths.localRenderReady {
            settingsRow(
                icon: "cpu",
                label: "Run local setup",
                detail: "~15 min"
            ) {
                showSetupAlert = true
            }
        } else if currentTerrainSource == .local {
            settingsRow(
                icon: "checkmark.circle",
                label: "Local terrain ready",
                detail: TerrainAssetPaths.localRenderedSizeString
            ) {
                showLocalDataInFinder()
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.blender(.medium, size: 18))
                .foregroundStyle(.primary)

            Text("Ares is made by Applied Curiosity, an independent research lab exploring ideas at the intersection of design and science.")
                .font(.blender(.book, size: 15))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(.bottom, 8)

            settingsRow(
                icon: "globe",
                label: "Ares Preview (GitHub)",
                trailingIcon: "arrow.up.right"
            ) {
                if let url = URL(string: "https://github.com/BenjaminHoppe/ares-preview") {
                    NSWorkspace.shared.open(url)
                }
            }

            settingsRow(
                icon: "at",
                label: "applied_curi",
                trailingIcon: "arrow.up.right"
            ) {
                if let url = URL(string: "https://x.com/applied_curi") {
                    NSWorkspace.shared.open(url)
                }
            }

            settingsRow(
                icon: "envelope",
                label: showCopied ? "Copied to clipboard" : "Email",
                trailingIcon: "square.on.square"
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("benjamin@benjaminhoppe.co", forType: .string)
                withAnimation(.easeOut(duration: 0.15)) {
                    showCopied = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showCopied = false
                    }
                }
            }
            .contentTransition(.interpolate)

            Text(appVersion)
                .font(.blender(.book, size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
        }
    }

    // MARK: - Components

    private func settingsSection<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.blender(.medium, size: 18))
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.blender(.book, size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }

            content()
        }
    }

    private func settingsRow(
        icon: String,
        label: String,
        detail: String? = nil,
        trailingIcon: String = "chevron.right",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(label)
                    .font(.blender(.medium, size: 14))
                    .foregroundStyle(.primary)

                Spacer()

                if let detail {
                    Text(detail)
                        .font(.blender(.book, size: 13))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: trailingIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private var currentTerrainSource: TerrainSource {
        TerrainSource(rawValue: terrainSourceMode) ?? .prebaked
    }

    private func clearLocalRenderedData() {
        TerrainAssetPaths.clearLocalRenderedData()
    }

    private func showLocalDataInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: TerrainAssetPaths.finderRevealDirectory(for: .local).path)
    }
}
