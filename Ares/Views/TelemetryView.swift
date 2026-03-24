import SwiftUI

struct TelemetryView: View {
    @ObservedObject var timekeeper: MarsTimekeeper
    @AppStorage("terrainSourceMode") private var terrainSourceMode = TerrainSource.prebaked.rawValue

    let coordinates: String
    let resolution: String
    let fieldOfView: String
    var enhanceEnabled: Bool = true

    private var isLocal: Bool {
        TerrainSource(rawValue: terrainSourceMode) == .local
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Telemetry")
                .font(.blender(.medium, size: 17))
                .foregroundStyle(.white)
                .padding(.bottom, 16)

            // MARK: - Navigation
            section("Navigation") {
                row("Coordinates", coordinates)
                row("Resolution", resolution)
                row("Field of View", fieldOfView)
            }

            // MARK: - Model
            section("Model") {
                row("Upscaling", enhanceEnabled ? "On" : "Off")
                row("Version", "Ares SR v0.5.1")
                row("Source", isLocal ? "Locally rendered" : "Pre-upscaled")
                if isLocal {
                    row("Hardware", "Neural Engine")
                }
            }

            // MARK: - Planetary
            section("Planetary", isLast: true) {
                row("MTC", timekeeper.mtc)
                row("Solar Longitude", String(format: "%.0f°", timekeeper.solarLongitude))
                row("Distance to Earth", timekeeper.distanceToEarth)
                row("Distance to Sun", timekeeper.distanceToSun)
                row("Orbital Velocity", timekeeper.orbitalVelocity)
                row("Light Delay", timekeeper.lightDelay)
                row("Population", "0")
            }
        }
        .padding(12)
        .frame(width: 245)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func section(_ title: String, isLast: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.blender(.medium, size: 13))
                .foregroundStyle(.white.opacity(0.6))

            content()
        }
        .padding(.bottom, isLast ? 0 : 20)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label.uppercased())
                .font(.blender(.medium, size: 13))
                .foregroundStyle(.white)

            Spacer(minLength: 8)

            Text(value)
                .font(.blender(.medium, size: 13))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }
}
