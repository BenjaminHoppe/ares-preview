import SwiftUI

struct AltitudeScaleBar: View {
    let trackHeight: CGFloat
    let visibleHeightKm: Double
    let minScale: CGFloat
    let maxScale: CGFloat
    let currentScale: CGFloat
    var onScaleChange: ((CGFloat, Bool) -> Void)?

    @AppStorage("useImperialUnits") private var useImperialUnits = false

    @State private var hoverY: CGFloat?
    @State private var dragFrameCount: Int = 0

    private let tickWidthMajor: CGFloat = 24
    private let tickWidthMinor: CGFloat = 12
    private let tickCount = 26
    private let majorEvery = 5

    var altitudeKm: Double {
        visibleHeightKm / 1.15
    }

    // Bottom = zoomed out, top = zoomed in
    private var thumbT: CGFloat {
        let logMin = log(Double(minScale))
        let logMax = log(Double(maxScale))
        let logCur = log(Double(currentScale))
        return CGFloat((logCur - logMin) / (logMax - logMin))
    }

    private var thumbY: CGFloat {
        trackHeight - thumbT * trackHeight
    }

    private func scaleForY(_ y: CGFloat) -> CGFloat {
        let t = 1.0 - (y / trackHeight)
        let logMin = log(Double(minScale))
        let logMax = log(Double(maxScale))
        let logScale = logMin + Double(t) * (logMax - logMin)
        return CGFloat(exp(logScale))
    }

    private func altitudeForY(_ y: CGFloat) -> Double {
        let s = scaleForY(y)
        // Altitude is inversely proportional to scale
        let baseAlt = visibleHeightKm / 1.15
        let baseScale = currentScale
        return baseAlt * Double(baseScale / s)
    }

    // Is a tick close enough to the thumb that its hover label would overlap?
    private func isNearThumb(_ tickY: CGFloat) -> Bool {
        abs(tickY - thumbY) < 20
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tick marks
            Canvas { context, size in
                for i in 0..<tickCount {
                    let t = CGFloat(i) / CGFloat(tickCount - 1)
                    let y = t * trackHeight
                    let isEndpoint = i == 0 || i == tickCount - 1
                    let isMajor = isEndpoint || i % majorEvery == 0
                    let w = isMajor ? tickWidthMajor : tickWidthMinor
                    let h: CGFloat = 1

                    let belowThumb = y >= thumbY
                    let opacity: Double
                    if belowThumb {
                        opacity = isMajor ? 1.0 : 0.5
                    } else {
                        opacity = 0.25
                    }

                    let pixelY: CGFloat
                    if i == 0 {
                        pixelY = 0
                    } else if i == tickCount - 1 {
                        pixelY = trackHeight - 1
                    } else {
                        pixelY = round(y)
                    }
                    let rect = CGRect(x: 0, y: pixelY, width: w, height: h)
                    context.fill(Path(rect), with: .color(.white.opacity(opacity)))
                }
            }

            // Hover altitude label — shows altitude at hovered tick position
            if let hy = hoverY, dragFrameCount == 0, !isNearThumb(hy) {
                let hoverAlt = altitudeForY(hy)
                Text(formatAltitude(hoverAlt))
                    .font(.blender(.medium, size: 13))
                    .foregroundStyle(.white)
                    .offset(x: tickWidthMajor + 12, y: hy - 8)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: hy)
            }

            // Thumb — same width as major tick
            Rectangle()
                .fill(.white)
                .frame(width: tickWidthMajor, height: 1)
                .offset(y: thumbY - 0.5)

            // Altitude label — right of the ticks
            VStack(alignment: .leading, spacing: 2) {
                Text("ALTITUDE")
                    .font(.blender(.medium, size: 13))
                    .foregroundStyle(.white)

                Text(formatAltitude(altitudeKm))
                    .font(.blender(.medium, size: 13))
                    .foregroundStyle(.white)
            }
            .offset(x: tickWidthMajor + 12, y: thumbY - 12)

            // Interaction layer — click and drag
            Color.clear
                .frame(width: tickWidthMajor + 80, height: trackHeight)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        // Snap to nearest tick
                        let nearestTick = nearestTickY(to: location.y)
                        hoverY = nearestTick
                    case .ended:
                        hoverY = nil
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFrameCount += 1
                            let y = min(max(value.location.y, 0), trackHeight)
                            let newScale = scaleForY(y)
                            // First frame = click (animate) unless near current thumb
                            let nearThumb = abs(y - thumbY) < 15
                            let shouldAnimate = dragFrameCount <= 1 && !nearThumb
                            onScaleChange?(newScale, shouldAnimate)
                        }
                        .onEnded { _ in
                            dragFrameCount = 0
                        }
                )
        }
        .frame(width: 160, height: trackHeight)
    }

    private func nearestTickY(to y: CGFloat) -> CGFloat {
        var closest: CGFloat = 0
        var minDist: CGFloat = .infinity
        for i in 0..<tickCount {
            let tickY = CGFloat(i) / CGFloat(tickCount - 1) * trackHeight
            let dist = abs(tickY - y)
            if dist < minDist {
                minDist = dist
                closest = tickY
            }
        }
        return closest
    }

    // MARK: - Formatting

    static func formatAltitude(_ km: Double, imperial: Bool = UserDefaults.standard.bool(forKey: "useImperialUnits")) -> String {
        if imperial {
            let miles = km * 0.621371
            if miles >= 1000 {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 0
                return "\(formatter.string(from: NSNumber(value: miles)) ?? "\(Int(miles))") mi"
            } else if miles >= 10 {
                return String(format: "%.0f mi", miles)
            } else if miles >= 1 {
                return String(format: "%.1f mi", miles)
            } else {
                return String(format: "%.0f ft", km * 3280.84)
            }
        }
        if km >= 1000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return "\(formatter.string(from: NSNumber(value: km)) ?? "\(Int(km))") km"
        } else if km >= 10 {
            return String(format: "%.0f km", km)
        } else if km >= 1 {
            return String(format: "%.1f km", km)
        } else {
            return String(format: "%.0f m", km * 1000)
        }
    }

    private func formatAltitude(_ km: Double) -> String {
        Self.formatAltitude(km, imperial: useImperialUnits)
    }

    static func comparableAltitude(_ km: Double) -> String {
        if km > 540 { return "Hubble Space Telescope Orbit" }
        if km > 400 { return "International Space Station Orbit" }
        if km > 160 { return "Low Earth Orbit" }
        if km > 100 { return "Kármán Line (Edge of Space)" }
        if km > 35 { return "Weather Balloon" }
        if km > 12 { return "Commercial Cruising Altitude" }
        if km > 8.8 { return "Summit of Mount Everest" }
        if km > 5 { return "Summit of Mount Denali" }
        if km > 1.5 { return "Burj Khalifa" }
        if km > 0.4 { return "Empire State Building" }
        if km > 0.1 { return "Statue of Liberty" }
        if km > 0.03 { return "10-Storey Building" }
        return "Three-Storey House"
    }
}
