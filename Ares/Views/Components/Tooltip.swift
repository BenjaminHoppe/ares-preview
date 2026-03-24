import SwiftUI

// MARK: - Tooltip View

struct TooltipView: View {
    let label: String
    let shortcut: String?

    init(_ label: String, shortcut: String? = nil) {
        self.label = label
        self.shortcut = shortcut
    }

    private var shortcutKeys: [String] {
        guard let shortcut else { return [] }
        return shortcut.map { String($0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.blender(.medium, size: 12))
                .foregroundStyle(.white)

            if !shortcutKeys.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(shortcutKeys.enumerated()), id: \.offset) { _, key in
                        TooltipKeyTile(key: key)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Key Tile

private struct TooltipKeyTile: View {
    let key: String

    private var isSingleChar: Bool { key.count == 1 }

    var body: some View {
        Text(key)
            .font(.blender(.medium, size: 10))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: isSingleChar ? 16 : nil, height: 16)
            .padding(.horizontal, isSingleChar ? 0 : 4)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

// MARK: - Tooltip Modifier

private struct TooltipModifier: ViewModifier {
    let label: String
    let shortcut: String?
    let position: TooltipPosition
    let horizontalAlignment: TooltipAlignment
    let offset: CGFloat
    let delay: Duration

    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    private var yOffset: CGFloat {
        position == .below ? offset : -offset
    }

    private var scaleAnchor: UnitPoint {
        position == .below ? .top : .bottom
    }

    private var overlayAlignment: Alignment {
        switch (position, horizontalAlignment) {
        case (.below, .center): return .bottom
        case (.below, .trailing): return .bottomTrailing
        case (.above, .center): return .top
        case (.above, .trailing): return .topTrailing
        }
    }

    private var tooltipContentAlignment: Alignment {
        switch horizontalAlignment {
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()

                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(for: delay)
                        if !Task.isCancelled {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showTooltip = true
                            }
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showTooltip = false
                    }
                }
            }
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        hoverTask?.cancel()
                        withAnimation(.easeOut(duration: 0.15)) {
                            showTooltip = false
                        }
                    }
            )
            .overlay(alignment: overlayAlignment) {
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: tooltipContentAlignment) {
                        if showTooltip {
                            TooltipView(label, shortcut: shortcut)
                                .fixedSize()
                                .offset(y: yOffset)
                                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: scaleAnchor)))
                                .allowsHitTesting(false)
                        }
                    }
            }
    }
}

// MARK: - Position & Alignment

enum TooltipPosition {
    case below
    case above
}

enum TooltipAlignment {
    case center
    case trailing
}

// MARK: - View Extension

extension View {
    func tooltip(_ label: String, shortcut: String? = nil, position: TooltipPosition = .below, alignment: TooltipAlignment = .center, offset: CGFloat = 18, delay: Duration = .milliseconds(300)) -> some View {
        self
            .modifier(TooltipModifier(label: label, shortcut: shortcut, position: position, horizontalAlignment: alignment, offset: offset, delay: delay))
    }
}
