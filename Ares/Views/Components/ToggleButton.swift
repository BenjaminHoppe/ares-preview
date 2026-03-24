import SwiftUI

struct ToggleButton: View {
    let icon: String
    @Binding var isActive: Bool

    @State private var isHovered = false

    private var backgroundFill: Color {
        if isActive { return .primary.opacity(0.08) }
        if isHovered { return .primary.opacity(0.12) }
        return .clear
    }

    var body: some View {
        Button {
            isActive.toggle()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(backgroundFill)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isActive)
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}
