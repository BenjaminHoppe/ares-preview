// Debug marker overlay + keyboard shortcuts — stashed from SampleSizeView.swift
// To restore: add `@State private var debugMarker: MarsCoordinate?` to the view,
// paste the overlay into the ZStack, and attach the key handlers to the GeometryReader.

// MARK: - State property
// @State private var debugMarker: MarsCoordinate?

// MARK: - Overlay (inside ZStack, after viewportOverlays)
/*
if let coord = debugMarker {
    let pos = screenPosition(for: coord, viewportSize: viewportSize)
    VStack(spacing: 2) {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
        Text("\(String(format: "%.2f", coord.lat))°N \(String(format: "%.2f", coord.lon))°E")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.85).cornerRadius(3))
    }
    .position(x: pos.x, y: pos.y - 16)
    .allowsHitTesting(false)
}
*/

// MARK: - Key handlers
/*
.onKeyPress(.init("x"), phases: .down) { _ in
    let pt = cursorPoint ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    let coord = coordinate(at: pt, viewportSize: viewportSize)
    debugMarker = coord
    NSLog("[Marker] Placed at %.3f°N, %.3f°E", coord.lat, coord.lon)
    return .handled
}
.onKeyPress(.init("d"), phases: .down) { _ in
    debugMarker = nil
    return .handled
}
.onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
    guard var m = debugMarker else { return .ignored }
    let nudge = PathfinderExperience.baseDegreesPerPoint(for: viewportSize) / Double(scale)
    m = MarsCoordinate(lat: m.lat + nudge, lon: m.lon)
    debugMarker = m
    return .handled
}
.onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
    guard var m = debugMarker else { return .ignored }
    let nudge = PathfinderExperience.baseDegreesPerPoint(for: viewportSize) / Double(scale)
    m = MarsCoordinate(lat: m.lat - nudge, lon: m.lon)
    debugMarker = m
    return .handled
}
.onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in
    guard var m = debugMarker else { return .ignored }
    let nudge = PathfinderExperience.baseDegreesPerPoint(for: viewportSize) / Double(scale)
    m = MarsCoordinate(lat: m.lat, lon: m.lon - nudge)
    debugMarker = m
    return .handled
}
.onKeyPress(.rightArrow, phases: [.down, .repeat]) { _ in
    guard var m = debugMarker else { return .ignored }
    let nudge = PathfinderExperience.baseDegreesPerPoint(for: viewportSize) / Double(scale)
    m = MarsCoordinate(lat: m.lat, lon: m.lon + nudge)
    debugMarker = m
    return .handled
}
*/
