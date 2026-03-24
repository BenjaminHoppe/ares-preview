// Debug overlay panel — stashed from SampleSizeView.swift
// Shows FPS, tier, mode, tiles, timing, inference, memory stats.
// Was displayed in top-right of viewport, replaced by viewportSizePanel.

/*
private func debugOverlay(level1Opacity: Double, level2Opacity: Double, level3Opacity: Double = 0) -> some View {
    let tierText: String
    if level3Opacity >= 0.99 {
        tierText = "Tier 3 (HiRISE 25 cm/px)"
    } else if level3Opacity > 0.01 {
        tierText = "Tier 2→3 (\(Int(level3Opacity * 100))%)"
    } else if level2Opacity >= 0.99 {
        tierText = "Tier 2 (HiRISE 1 m/px)"
    } else if level2Opacity > 0.01 {
        tierText = "Tier 1→2 (\(Int(level2Opacity * 100))%)"
    } else if level1Opacity >= 0.99 {
        tierText = "Tier 1 (CTX 24 m/px)"
    } else if level1Opacity > 0.01 {
        tierText = "Tier 0→1 (\(Int(level1Opacity * 100))%)"
    } else {
        tierText = "Tier 0 (Viking)"
    }

    let ready = model.readyLevel1TileCount
    let total = model.totalLevel1TileCount
    let elapsed = model.enhancementElapsedSeconds
    let mins = Int(elapsed) / 60
    let secs = Int(elapsed) % 60

    let tilesText = model.isEnhancing
        ? "Tiles: \(ready)/\(total) enhancing"
        : total > 0 ? "Tiles: \(ready)/\(total) ready" : "Tiles: —"

    let timeText: String
    if model.isEnhancing {
        timeText = mins > 0 ? String(format: "Time: %dm %02ds", mins, secs) : String(format: "Time: %ds", secs)
    } else if elapsed > 0 {
        timeText = mins > 0 ? String(format: "Done: %dm %02ds", mins, secs) : String(format: "Done: %ds", secs)
    } else {
        timeText = "Time: —"
    }

    let inferenceText: String = model.averageInferenceMs > 0
        ? String(format: "Inference: %.0fms/tile", model.averageInferenceMs)
        : "Inference: —"

    let modeLabel = ctxAlwaysMode ? "CTX-always" : "Crossfade"
    let sourceLabel = model.hiriseSourceLabel
    let modeText = "\(modeLabel) · \(sourceLabel)"
    let colourText = model.colourMode ? "Colour: On" : "Colour: Off"

    return VStack(alignment: .trailing, spacing: 3) {
        Text("FPS: \(model.fps)")
        Text(tierText)
        Text(modeText)
        Text(colourText)
        Text(tilesText)
        Text(timeText)
        Text(inferenceText)
        Text("Mem: \(model.memoryMB) MB")
    }
    .font(.system(size: 10, weight: .medium, design: .monospaced))
    .foregroundStyle(.white.opacity(0.68))
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.black.opacity(0.6))
            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
    )
}
*/
