import SwiftUI

struct ContentView: View {
    @State private var isFullScreen = false
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    // Toolbar state — persisted across launches
    @AppStorage("showPOI") private var showPOI = true
    @AppStorage("showAltimeter") private var showAltimeter = true
    @AppStorage("showTelemetry") private var showTelemetry = true
    @AppStorage("colourMode") private var colourMode = true
    @AppStorage("showEnhance") private var showEnhance = true
    @AppStorage("showCTX") private var showCTX = true
    @AppStorage("showSettings") private var showSettings = false
    @AppStorage("terrainSourceMode") private var terrainSourceMode = TerrainSource.prebaked.rawValue

    @State private var viewportScale: CGFloat = 1.0
    @State private var viewportOffset: CGSize = .zero

    private var viewportCornerRadius: CGFloat { isFullScreen ? 0 : 12 }
    private var shellPadding: CGFloat { isFullScreen ? 0 : 8 }

    var body: some View {
        if !hasCompletedSetup {
            OnboardingView(hasCompletedSetup: $hasCompletedSetup)
                .background(Color.black)
                .ignoresSafeArea()
                .frame(minWidth: 800, minHeight: 700)
        } else {
            mainAppView
        }
    }

    private var mainAppView: some View {
        VStack(spacing: 0) {
            if !isFullScreen {
                TopBar(
                    showPOI: $showPOI,
                    showAltimeter: $showAltimeter,
                    showTelemetry: $showTelemetry,
                    colourMode: $colourMode,
                    showEnhance: $showEnhance,
                    showCTX: $showCTX,
                    showSettings: $showSettings
                )
                .zIndex(1)
                .ignoresSafeArea(edges: .top)
            }

            HStack(spacing: 0) {
                SampleSizeView(colourMode: $colourMode, showPOI: $showPOI, showEnhance: $showEnhance, showTelemetry: $showTelemetry, showCTX: $showCTX, showAltimeter: $showAltimeter, isFullScreen: isFullScreen, scale: $viewportScale, offset: $viewportOffset)
                    .id(terrainSourceMode)
                    .clipShape(RoundedRectangle(cornerRadius: viewportCornerRadius, style: .continuous))
            }
            .padding([.horizontal, .bottom], shellPadding)
        }
        .overlay(alignment: .topTrailing) {
            if isFullScreen {
                ToolbarItems(
                    showPOI: $showPOI,
                    showAltimeter: $showAltimeter,
                    showTelemetry: $showTelemetry,
                    colourMode: $colourMode,
                    showEnhance: $showEnhance,
                    showCTX: $showCTX,
                    showSettings: $showSettings
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 8)
                .padding(.trailing, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isFullScreen)
        .background(isFullScreen ? AnyShapeStyle(.black) : AnyShapeStyle(.regularMaterial))
        .ignoresSafeArea()
        .frame(minWidth: 800, minHeight: 700)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .overlay {
            ZStack {
                if showSettings {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { showSettings = false }
                        .transition(.opacity)

                    SettingsView(isPresented: $showSettings)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: showSettings)
        }
        .environment(\.colorScheme, .dark)
    }
}
