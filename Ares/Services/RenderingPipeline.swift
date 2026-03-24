import Foundation
import CoreGraphics
import ImageIO

/// Orchestrates the full terrain enhancement pipeline across all three tiers.
/// Tracks progress, supports resume, and saves results as strips to disk.
@MainActor
final class RenderingPipeline: ObservableObject {
    enum Phase: Equatable {
        case idle
        case rendering
        case complete
    }

    enum TierStatus: Equatable {
        case pending
        case active(completed: Int, total: Int)
        case done(tiles: Int)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var tier1Status: TierStatus = .pending
    @Published private(set) var tier2Status: TierStatus = .pending
    @Published private(set) var tier3Status: TierStatus = .pending
    @Published private(set) var averageInferenceMs: Double = 0
    @Published private(set) var totalGeneratedBytes: Int64 = 0
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var currentTileID: String = ""

    /// Set to true to simulate rendering without actual ML inference (for UI testing)
    static let mockMode = false

    private lazy var tileManager = TileManager()
    private let processingQueue = DispatchQueue(label: "com.arespreview.rendering-pipeline", qos: .userInitiated, attributes: .concurrent)
    private var startTime: CFAbsoluteTime = 0
    private var totalInferenceMs: Double = 0
    private var totalInferencePasses: Int = 0
    private var timer: Timer?

    // MARK: - Cache directories

    private static let tier1CacheDir = TerrainAssetPaths.localLevel1EnhancedDirectory
    private static let tier1RawCacheDir = TerrainAssetPaths.localLevel1RawDirectory
    private static let tier2StripDir = TerrainAssetPaths.localTier2StripDirectory
    private static let tier3StripDir = TerrainAssetPaths.localTier3StripDirectory

    // Tier 3 source range (matches PathfinderExplorerModel constants)
    private static let tier3RowStart = 49
    private static let tier3RowEnd = 54
    private static let tier3ColStart = 17
    private static let tier3ColEnd = 25

    // MARK: - Public API

    func startRendering() {
        guard phase == .idle else { return }
        phase = .rendering
        startTime = CFAbsoluteTimeGetCurrent()

        // Elapsed timer
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds = CFAbsoluteTimeGetCurrent() - (self?.startTime ?? 0)
            }
        }

        Task {
            if Self.mockMode {
                await mockRender()
            } else {
                await renderTier1()
                await renderTier2()
                await renderTier3()
            }

            timer?.invalidate()
            elapsedSeconds = CFAbsoluteTimeGetCurrent() - startTime
            phase = .complete
        }
    }

    // MARK: - Tier 1: CTX tiles

    private func renderTier1() async {
        let descriptors = CTXTileLoader.rawTiles(intersecting: GeoRect(lonMin: 312, lonMax: 344, latMin: 8, latMax: 28))
        let total = descriptors.count
        tier1Status = .active(completed: 0, total: total)

        var completed = 0
        for descriptor in descriptors {
            currentTileID = descriptor.id

            let cacheURL = Self.tier1CacheDir.appendingPathComponent("\(descriptor.id).jpg")
            let rawCacheURL = Self.tier1RawCacheDir.appendingPathComponent("\(descriptor.id).jpg")

            // Skip if already cached
            if FileManager.default.fileExists(atPath: cacheURL.path) &&
               FileManager.default.fileExists(atPath: rawCacheURL.path) {
                completed += 1
                tier1Status = .active(completed: completed, total: total)
                continue
            }

            // Load raw tile
            guard let rawImage = await loadOnQueue({ CTXTileLoader.loadLevel1Image(for: descriptor) }) else {
                completed += 1
                tier1Status = .active(completed: completed, total: total)
                continue
            }

            // Convert to grayscale and save raw
            let grayscale = await loadOnQueue({ TileManager.makeGrayscaleImage(from: rawImage) })
            if let grayscale {
                await saveOnQueue(grayscale, to: rawCacheURL)
            }

            // Enhance
            let enhanced = await tileManager.enhanceLevel2Tile(grayscale ?? rawImage, tileID: descriptor.id)
            if let enhanced {
                totalInferenceMs += enhanced.elapsedMs
                totalInferencePasses += 1
                averageInferenceMs = totalInferenceMs / Double(totalInferencePasses)
                await saveOnQueue(enhanced.image, to: cacheURL)
            } else if let grayscale {
                // Fallback: save grayscale as "enhanced"
                await saveOnQueue(grayscale, to: cacheURL)
            }

            completed += 1
            tier1Status = .active(completed: completed, total: total)
        }

        tier1Status = .done(tiles: total)
    }

    // MARK: - Tier 2: HiRISE downsampled strips

    private func renderTier2() async {
        let gridRows = HiRISETier2Loader.gridRows  // 27
        let gridCols = HiRISETier2Loader.gridCols  // 8
        let total = gridRows * gridCols

        if Self.jpegFileCount(in: Self.tier2StripDir) >= TerrainAssetPaths.tier2ExpectedStripCount {
            tier2Status = .done(tiles: total)
            return
        }

        tier2Status = .active(completed: 0, total: total)

        // Enhance all tiles
        var enhancedTiles: [String: CGImage] = [:]
        var rawTiles: [String: CGImage] = [:]
        var completed = 0

        for row in 0..<gridRows {
            for col in 0..<gridCols {
                let descriptor = HiRISETier2TileDescriptor(row: row, column: col)
                currentTileID = descriptor.id

                guard let rawImage = await loadOnQueue({ HiRISETier2Loader.loadImage(for: descriptor) }) else {
                    completed += 1
                    tier2Status = .active(completed: completed, total: total)
                    continue
                }

                let grayscale = await loadOnQueue({
                    TileManager.makeGrayscaleImage(from: rawImage)
                }) ?? rawImage
                rawTiles[descriptor.id] = grayscale

                if let enhanced = await tileManager.enhanceLevel2Tile(grayscale, tileID: descriptor.id) {
                    totalInferenceMs += enhanced.elapsedMs
                    totalInferencePasses += 1
                    averageInferenceMs = totalInferenceMs / Double(totalInferencePasses)
                    enhancedTiles[descriptor.id] = enhanced.image
                } else {
                    // Fallback: bicubic upscale
                    let upscaled = await loadOnQueue({
                        TileManager.resizeImage(grayscale, to: CGSize(width: 2048, height: 2048), grayscale: true)
                    })
                    if let upscaled { enhancedTiles[descriptor.id] = upscaled }
                }

                completed += 1
                tier2Status = .active(completed: completed, total: total)
            }
        }

        // Assemble into 9 row-based strips and colourise
        currentTileID = "assembling strips"
        let stripCount = 9
        let rowsPerStrip = gridRows / stripCount  // 3
        let tileSize = HiRISETier2Loader.tileSize  // 512
        let enhancedTileSize = 2048

        try? FileManager.default.createDirectory(at: Self.tier2StripDir, withIntermediateDirectories: true)

        let engine = ColourEngine.shared
        await loadOnQueue({ engine.prepareChromaTexture() })

        for stripIndex in 0..<stripCount {
            let stripRowStart = stripIndex * rowsPerStrip
            let stripGeo = GeoRect(
                lonMin: HiRISETier2Loader.lonMin,
                lonMax: HiRISETier2Loader.lonMax,
                latMin: HiRISETier2Loader.latMax - Double(stripRowStart + rowsPerStrip) * HiRISETier2Loader.degreesPerTileLat,
                latMax: HiRISETier2Loader.latMax - Double(stripRowStart) * HiRISETier2Loader.degreesPerTileLat
            )

            // Raw BW strip
            if let rawStrip = await loadOnQueue({
                Self.assembleStrip(tiles: rawTiles, rows: stripRowStart..<(stripRowStart + rowsPerStrip), cols: 0..<gridCols, tileSize: tileSize, prefix: "t2_")
            }) {
                let url = Self.tier2StripDir.appendingPathComponent("tier2_raw_strip\(stripIndex).jpg")
                await saveOnQueue(rawStrip, to: url)

                // Raw colour strip
                if let coloured = await loadOnQueue({ engine.composite(luminanceTile: rawStrip, tileRect: stripGeo) }) {
                    let colURL = Self.tier2StripDir.appendingPathComponent("tier2_raw_colour_strip\(stripIndex).jpg")
                    await saveOnQueue(coloured, to: colURL)
                }
            }

            // Enhanced BW strip
            if let enhStrip = await loadOnQueue({
                Self.assembleStrip(tiles: enhancedTiles, rows: stripRowStart..<(stripRowStart + rowsPerStrip), cols: 0..<gridCols, tileSize: enhancedTileSize, prefix: "t2_")
            }) {
                let url = Self.tier2StripDir.appendingPathComponent("tier2_enhanced_strip\(stripIndex).jpg")
                await saveOnQueue(enhStrip, to: url)

                // Enhanced colour strip
                if let coloured = await loadOnQueue({ engine.composite(luminanceTile: enhStrip, tileRect: stripGeo) }) {
                    let colURL = Self.tier2StripDir.appendingPathComponent("tier2_enhanced_colour_strip\(stripIndex).jpg")
                    await saveOnQueue(coloured, to: colURL)
                }
            }
        }

        tier2Status = .done(tiles: total)
    }

    // MARK: - Tier 3: HiRISE native strips

    private func renderTier3() async {
        let rows = Self.tier3RowStart...Self.tier3RowEnd
        let cols = Self.tier3ColStart...Self.tier3ColEnd
        let total = rows.count * cols.count

        if Self.jpegFileCount(in: Self.tier3StripDir) >= TerrainAssetPaths.tier3ExpectedStripCount {
            tier3Status = .done(tiles: total)
            return
        }

        tier3Status = .active(completed: 0, total: total)

        // Enhance all tiles
        var enhancedTiles: [String: CGImage] = [:]
        var rawTiles: [String: CGImage] = [:]
        var completed = 0

        for row in rows {
            for col in cols {
                let descriptor = HiRISETileDescriptor(row: row, column: col)
                currentTileID = descriptor.id

                guard let rawImage = await loadOnQueue({ HiRISETileLoader.loadImage(for: descriptor) }) else {
                    completed += 1
                    tier3Status = .active(completed: completed, total: total)
                    continue
                }

                let grayscale = await loadOnQueue({
                    TileManager.makeGrayscaleImage(from: rawImage)
                }) ?? rawImage
                rawTiles[descriptor.id] = grayscale

                if let enhanced = await tileManager.enhanceLevel2Tile(grayscale, tileID: descriptor.id) {
                    totalInferenceMs += enhanced.elapsedMs
                    totalInferencePasses += 1
                    averageInferenceMs = totalInferenceMs / Double(totalInferencePasses)
                    enhancedTiles[descriptor.id] = enhanced.image
                } else {
                    let upscaled = await loadOnQueue({
                        TileManager.resizeImage(grayscale, to: CGSize(width: 2048, height: 2048), grayscale: true)
                    })
                    if let upscaled { enhancedTiles[descriptor.id] = upscaled }
                }

                completed += 1
                tier3Status = .active(completed: completed, total: total)
            }
        }

        // Assemble into 9 column-based strips and colourise
        currentTileID = "assembling strips"
        let tileSize = HiRISETileLoader.tileSize  // 512
        let enhancedTileSize = 2048

        try? FileManager.default.createDirectory(at: Self.tier3StripDir, withIntermediateDirectories: true)

        let engine = ColourEngine.shared
        await loadOnQueue({ engine.prepareChromaTexture() })

        for (ci, col) in cols.enumerated() {
            let stripGeo = GeoRect(
                lonMin: HiRISETileLoader.lonMin + Double(col) * HiRISETileLoader.degreesPerTileLon,
                lonMax: HiRISETileLoader.lonMin + Double(col + 1) * HiRISETileLoader.degreesPerTileLon,
                latMin: HiRISETileLoader.latMax - Double(Self.tier3RowEnd + 1) * HiRISETileLoader.degreesPerTileLat,
                latMax: HiRISETileLoader.latMax - Double(Self.tier3RowStart) * HiRISETileLoader.degreesPerTileLat
            )

            // Raw BW column strip
            if let rawStrip = await loadOnQueue({
                Self.assembleColumnStrip(tiles: rawTiles, rows: rows, col: col, tileSize: tileSize)
            }) {
                let url = Self.tier3StripDir.appendingPathComponent("tier3_raw_strip\(ci).jpg")
                await saveOnQueue(rawStrip, to: url)

                if let coloured = await loadOnQueue({ engine.composite(luminanceTile: rawStrip, tileRect: stripGeo) }) {
                    let colURL = Self.tier3StripDir.appendingPathComponent("tier3_raw_colour_strip\(ci).jpg")
                    await saveOnQueue(coloured, to: colURL)
                }
            }

            // Enhanced BW column strip
            if let enhStrip = await loadOnQueue({
                Self.assembleColumnStrip(tiles: enhancedTiles, rows: rows, col: col, tileSize: enhancedTileSize)
            }) {
                let url = Self.tier3StripDir.appendingPathComponent("tier3_enhanced_strip\(ci).jpg")
                await saveOnQueue(enhStrip, to: url)

                if let coloured = await loadOnQueue({ engine.composite(luminanceTile: enhStrip, tileRect: stripGeo) }) {
                    let colURL = Self.tier3StripDir.appendingPathComponent("tier3_enhanced_colour_strip\(ci).jpg")
                    await saveOnQueue(coloured, to: colURL)
                }
            }
        }

        tier3Status = .done(tiles: total)
    }

    // MARK: - Strip assembly

    /// Assemble a row-based strip from a dictionary of tiles.
    private nonisolated static func assembleStrip(
        tiles: [String: CGImage],
        rows: Range<Int>,
        cols: Range<Int>,
        tileSize: Int,
        prefix: String
    ) -> CGImage? {
        let width = cols.count * tileSize
        let height = rows.count * tileSize

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .none

        for (ri, row) in rows.enumerated() {
            for (ci, col) in cols.enumerated() {
                let id = "\(prefix)\(String(format: "%04d_%04d", row, col))"
                guard let tile = tiles[id] else { continue }
                let originY = height - ((ri + 1) * tileSize)
                context.draw(tile, in: CGRect(x: ci * tileSize, y: originY, width: tileSize, height: tileSize))
            }
        }

        return context.makeImage()
    }

    /// Assemble a column-based strip (one column, all rows).
    private nonisolated static func assembleColumnStrip(
        tiles: [String: CGImage],
        rows: ClosedRange<Int>,
        col: Int,
        tileSize: Int
    ) -> CGImage? {
        let width = tileSize
        let height = rows.count * tileSize

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .none

        for (ri, row) in rows.enumerated() {
            let id = String(format: "%04d_%04d", row, col)
            guard let tile = tiles[id] else { continue }
            let originY = height - ((ri + 1) * tileSize)
            context.draw(tile, in: CGRect(x: 0, y: originY, width: tileSize, height: tileSize))
        }

        return context.makeImage()
    }

    // MARK: - Helpers

    private func loadOnQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            processingQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func loadOnQueue(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            processingQueue.async {
                work()
                continuation.resume()
            }
        }
    }

    // MARK: - Mock mode

    private func mockRender() async {
        // Tier 1: 61 tiles
        let t1Total = 61
        tier1Status = .active(completed: 0, total: t1Total)
        for i in 1...t1Total {
            currentTileID = "MurrayLab_CTX_V01_E\(324 + i % 8)_N\(8 + i / 8)"
            try? await Task.sleep(for: .milliseconds(40))
            totalGeneratedBytes += Int64.random(in: 200_000...400_000)
            totalInferenceMs += Double.random(in: 800...1600)
            totalInferencePasses += 1
            averageInferenceMs = totalInferenceMs / Double(totalInferencePasses)
            tier1Status = .active(completed: i, total: t1Total)
        }
        tier1Status = .done(tiles: t1Total)

        // Tier 2: 216 tiles
        let t2Total = 216
        tier2Status = .active(completed: 0, total: t2Total)
        for i in 1...t2Total {
            currentTileID = String(format: "t2_%04d_%04d", i / 8, i % 8)
            try? await Task.sleep(for: .milliseconds(20))
            totalGeneratedBytes += Int64.random(in: 300_000...600_000)
            totalInferenceMs += Double.random(in: 400...800)
            totalInferencePasses += 1
            averageInferenceMs = totalInferenceMs / Double(totalInferencePasses)
            tier2Status = .active(completed: i, total: t2Total)
        }
        tier2Status = .done(tiles: t2Total)

        // Tier 3: 54 tiles
        let t3Total = 54
        tier3Status = .active(completed: 0, total: t3Total)
        for i in 1...t3Total {
            currentTileID = String(format: "%04d_%04d", 49 + i / 9, 17 + i % 9)
            try? await Task.sleep(for: .milliseconds(30))
            totalGeneratedBytes += Int64.random(in: 300_000...500_000)
            totalInferenceMs += Double.random(in: 400...700)
            totalInferencePasses += 1
            averageInferenceMs = totalInferenceMs / Double(totalInferencePasses)
            tier3Status = .active(completed: i, total: t3Total)
        }
        tier3Status = .done(tiles: t3Total)
    }

    private func saveOnQueue(_ image: CGImage, to url: URL, quality: CGFloat = 0.92) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            processingQueue.async { [weak self] in
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
                    continuation.resume()
                    return
                }
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                CGImageDestinationFinalize(dest)

                if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                    Task { @MainActor in
                        self?.totalGeneratedBytes += size
                    }
                }
                continuation.resume()
            }
        }
    }

    private nonisolated static func jpegFileCount(in directory: URL) -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }

        return contents.reduce(into: 0) { count, file in
            if ["jpg", "jpeg"].contains(file.pathExtension.lowercased()) {
                count += 1
            }
        }
    }
}
