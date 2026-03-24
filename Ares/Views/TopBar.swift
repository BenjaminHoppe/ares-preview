import SwiftUI
import AppKit

let topBarHeight: CGFloat = 44

struct TopBar: View {
    @Binding var showPOI: Bool
    @Binding var showAltimeter: Bool
    @Binding var showTelemetry: Bool
    @Binding var colourMode: Bool
    @Binding var showEnhance: Bool
    @Binding var showCTX: Bool
    @Binding var showSettings: Bool

    var body: some View {
        ZStack {
            WindowDragView()

            TrafficLightPositioner(barHeight: topBarHeight)
                .frame(width: 0, height: 0)

            HStack(spacing: 0) {
                Spacer()

                ToolbarItems(
                    showPOI: $showPOI,
                    showAltimeter: $showAltimeter,
                    showTelemetry: $showTelemetry,
                    colourMode: $colourMode,
                    showEnhance: $showEnhance,
                    showCTX: $showCTX,
                    showSettings: $showSettings
                )
                .padding(.trailing, 12)
            }
        }
        .frame(height: topBarHeight)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Toolbar layout

private let dividerColor = Color.primary.opacity(0.10)

struct ToolbarItems: View {
    @Binding var showPOI: Bool
    @Binding var showAltimeter: Bool
    @Binding var showTelemetry: Bool
    @Binding var colourMode: Bool
    @Binding var showEnhance: Bool
    @Binding var showCTX: Bool
    @Binding var showSettings: Bool
    @AppStorage("markerMode") private var markerMode = false

    var body: some View {
        HStack(spacing: 8) {
            // ToggleButton(icon: "mappin.circle", isActive: $markerMode)
            //     .tooltip("Marker Tool", shortcut: "M", position: .below)
            ToggleButton(icon: "rectangle.expand.vertical", isActive: $showAltimeter)
                .tooltip("Altimeter", shortcut: "A", position: .below)
            ToggleButton(icon: "mappin.and.ellipse", isActive: $showPOI)
                .tooltip("Points of Interest", shortcut: "P", position: .below)

            ToggleButton(icon: "gauge.with.dots.needle.67percent", isActive: $showTelemetry)
                .tooltip("Telemetry", shortcut: "T", position: .below)

            ToolbarDivider()

            ToggleButton(icon: "wand.and.stars", isActive: $showEnhance)
                .tooltip("Upscaling", shortcut: "U", position: .below)
            ToggleButton(icon: "circle.lefthalf.filled", isActive: $colourMode)
                .tooltip("Colour", shortcut: "C", position: .below)

            ToolbarDivider()
                .padding(.horizontal, -2)

            ToolbarButton(icon: "gearshape") {
                showSettings = true
            }
            .tooltip("Settings", shortcut: "⌘,", position: .below, alignment: .trailing)
        }
    }
}

private struct ToolbarButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

private struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(width: 1, height: 16)
    }
}

// MARK: - Traffic light repositioning

struct TrafficLightPositioner: NSViewRepresentable {
    let barHeight: CGFloat
    var insetX: CGFloat = 4

    func makeNSView(context: Context) -> PositionerNSView {
        PositionerNSView(barHeight: barHeight, insetX: insetX)
    }

    func updateNSView(_ nsView: PositionerNSView, context: Context) {}
}

final class PositionerNSView: NSView {
    let barHeight: CGFloat
    let insetX: CGFloat
    private var resizeObserver: NSObjectProtocol?

    init(barHeight: CGFloat, insetX: CGFloat) {
        self.barHeight = barHeight
        self.insetX = insetX
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var fullScreenObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        DispatchQueue.main.async { self.reposition() }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.reposition() }
        fullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.reposition() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let obs = resizeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = fullScreenObserver { NotificationCenter.default.removeObserver(obs) }
    }

    func reposition() {
        guard let window = window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)

        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = isFullScreen ? 0 : 16
            frameView.layer?.masksToBounds = true
        }

        guard !isFullScreen else { return }

        let targetCenterFromTop = barHeight / 2
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { type in
            guard let button = window.standardWindowButton(type),
                  let superview = button.superview else { return }
            var f = button.frame
            f.origin.y = superview.bounds.height - targetCenterFromTop - f.height / 2
            f.origin.x += insetX
            button.setFrameOrigin(f.origin)
        }
    }
}

// MARK: - Window Drag

struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView { WindowDragNSView() }
    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
