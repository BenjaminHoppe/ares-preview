import AppKit
import SwiftUI

private enum PathfinderExperience {
    static let worldRect = GeoRect(lonMin: 312.0, lonMax: 344.0, latMin: 8.0, latMax: 28.0)
    static let pathfinder = MarsCoordinate(lat: 19.10, lon: 326.75)

    // Camera model: degrees-per-pixel is frozen on first render so content never shifts
    // on window resize. At scale=1 the tile coverage fills the initial viewport.
    private static var _frozenDpp: Double?
    static func baseDegreesPerPoint(for viewportSize: CGSize) -> Double {
        if let frozen = _frozenDpp { return frozen }
        let dpp = min(tileCoverageRect.width / Double(viewportSize.width),
                      tileCoverageRect.height / Double(viewportSize.height))
        _frozenDpp = dpp
        return dpp
    }

    // Far image rect: must be large enough that the Viking base layer fills ANY viewport
    // at ANY pan position within worldRect, at scale=1. 130°×100° covers viewports up to ~4800×3700pt.
    static let farRect = GeoRect(lonMin: 230, lonMax: 360, latMin: -24, latMax: 76)

    static let farImageWidth = 2048
    static let level1WorkingWidth = 512
    static let tier2Enabled = true
    static let tier3Enabled = true
    static let maxVisibleLevel2Tiles = 30
    static let maxZoomScale: CGFloat = 30000

    // CTX tile coverage (the actual data extent — 8 lon × 5 lat tiles at 4° each)
    static let tileCoverageRect = GeoRect(lonMin: 312, lonMax: 344, latMin: 8, latMax: 28)

    /// Minimum zoom so CTX tile coverage always fills the viewport (scaledToFill).
    static func minZoomScale(for viewportSize: CGSize) -> CGFloat {
        let frozenDpp = baseDegreesPerPoint(for: viewportSize)
        let ppp = 1.0 / frozenDpp
        let coveredW = tileCoverageRect.width * ppp
        let coveredH = tileCoverageRect.height * ppp
        // Scale needed so coverage fills viewport on both axes
        return max(CGFloat(Double(viewportSize.width) / coveredW),
                   CGFloat(Double(viewportSize.height) / coveredH))
    }
    static let minZoomScale: CGFloat = 1.0  // fallback for non-viewport contexts

    static let tier1StartKm = 500.0
    static let tier1EndKm = 220.0
    static let tier2StartKm = 30.0
    static let tier2EndKm = 8.0

    static let tier3StartKm = 3.5
    static let tier3EndKm = 1.5
    static let maxVisibleLevel3Tiles = 40
    static let hiriseTier2CoverageRect = HiRISETier2Loader.coverageRect
    static let hiriseCoverageRect = HiRISETileLoader.coverageRect

    // Tight crop around the Pathfinder lander — comfortably inside Tier 2 coverage
    static let tier3CropRect = GeoRect(
        lonMin: 326.735921016403, lonMax: 326.756342077218,
        latMin: 19.091403914255, latMax: 19.104454220776
    )

    static let pointsOfInterest: [(name: String, coordinate: MarsCoordinate)] = [
        ("PATHFINDER", MarsCoordinate(lat: 19.097090437014433, lon: 326.74787446541995)),
        ("SOJOURNER", MarsCoordinate(lat: 19.09716405897673, lon: 326.7478237526299)),
        ("BACKSHELL", MarsCoordinate(lat: 19.09276784432445, lon: 326.74942915137257)),
        ("PARACHUTE", MarsCoordinate(lat: 19.0925177711737, lon: 326.74918840933134)),
        ("POSSIBLE\nHEATSHIELD DEBRIS", MarsCoordinate(lat: 19.091215051974647, lon: 326.7527646329015)),
    ]

    static let marsRadiusKm = 3389.5
    static let kmPerDegreeLat = 2 * Double.pi * marsRadiusKm / 360.0

    static func kmPerDegreeLon(at latitude: Double) -> Double {
        kmPerDegreeLat * cos(latitude * .pi / 180.0)
    }
}

private enum Level1TilePhase {
    case loading
    case ready(CGImage)
    case failed
}

private struct Level1TileRenderState: Identifiable {
    let descriptor: CTXRawTileDescriptor
    var phase: Level1TilePhase
    var elapsedMs: Double?
    var lastAccess: Date

    var id: String { descriptor.id }
}

private struct IndexedStrip: Identifiable {
    let index: Int
    let image: CGImage

    var id: Int { index }
}

@MainActor
private final class PathfinderExplorerModel: ObservableObject {
    @Published var farImage: CGImage?
    @Published var level1Tiles: [String: Level1TileRenderState] = [:]
    // Pre-built Tier 2 mosaic strips — loaded from disk, toggle is a pointer swap.
    private var tier2EnhancedBW: [IndexedStrip] = []
    private var tier2EnhancedColour: [IndexedStrip] = []
    private var tier2RawBW: [IndexedStrip] = []
    private var tier2RawColour: [IndexedStrip] = []
    nonisolated static let tier2StripCount = 9
    private nonisolated static let preferSeamSafeTier2Strips = true
    private nonisolated static let tier3SourceRowStart = 49
    private nonisolated static let tier3SourceRowEnd = 54
    private nonisolated static let tier3SourceColStart = 17
    private nonisolated static let tier3SourceColEnd = 25

    private var useRawTier2Strips: Bool {
        showRawTiles || Self.preferSeamSafeTier2Strips
    }

    var activeTier2Strips: [IndexedStrip] {
        if useRawTier2Strips {
            return colourMode ? tier2RawColour : tier2RawBW
        } else {
            return colourMode ? tier2EnhancedColour : tier2EnhancedBW
        }
    }

    // Pre-built Tier 3 mosaics — composited from column strips at load time.
    private var tier3EnhancedBWMosaic: CGImage?
    private var tier3EnhancedColourMosaic: CGImage?
    private var tier3RawBWMosaic: CGImage?
    private var tier3RawColourMosaic: CGImage?
    private(set) var tier3Loaded = false
    nonisolated static let tier3StripCount = 9

    var activeTier3Mosaic: CGImage? {
        if showRawTiles {
            return colourMode ? tier3RawColourMosaic : tier3RawBWMosaic
        } else {
            return colourMode ? tier3EnhancedColourMosaic : tier3EnhancedBWMosaic
        }
    }

    var hiriseSourceLabel: String {
        if showRawTiles {
            return "Raw (T)"
        }
        if Self.preferSeamSafeTier2Strips {
            return "Raw (T2 seam-safe)"
        }
        return "Enhanced (T)"
    }
    @Published var fps: Int = 0
    @Published var memoryMB: Int = 0
    @Published var totalLevel1TileCount: Int = 0
    @Published var level1CompletedCount: Int = 0
    @Published var isEnhancing: Bool = false
    @Published var enhancementElapsedSeconds: Double = 0
    @Published var totalInferenceMs: Double = 0
    @Published var colourMode: Bool = true
    @Published var showRawTiles: Bool = false
    @Published private(set) var colourisedL1Cache: [String: CGImage] = [:]
    @Published private(set) var tier2Ready: Bool = false
    @Published private(set) var tier3Ready: Bool = false
    private(set) var tier2Loaded = false
    private var rawL1Cache: [String: CGImage] = [:]

    private lazy var tileManager = TileManager()
    private let processingQueue = DispatchQueue(label: "com.arespreview.pathfinder-processing", qos: .userInitiated, attributes: .concurrent)
    private var level1LoadTasks: [String: Task<Void, Never>] = [:]
    private var didStartInitialLoad = false
    private(set) var allLevel1Preloaded = false
    private var enhancementStartTime: CFAbsoluteTime = 0
    private var fpsTarget: FPSDisplayLinkTarget?

    var orderedLevel1Tiles: [Level1TileRenderState] {
        level1Tiles.values.sorted {
            if $0.descriptor.latSW == $1.descriptor.latSW {
                return $0.descriptor.lonSW < $1.descriptor.lonSW
            }
            return $0.descriptor.latSW > $1.descriptor.latSW
        }
    }

    var loadingTileCount: Int {
        level1Tiles.values.filter {
            if case .loading = $0.phase { return true }
            return false
        }.count
    }

    var readyLevel1TileCount: Int {
        level1Tiles.values.filter { if case .ready = $0.phase { return true }; return false }.count
    }

    var averageInferenceMs: Double {
        let count = readyLevel1TileCount
        guard count > 0 else { return 0 }
        return totalInferenceMs / Double(count)
    }

    func loadInitialAssets() async {
        guard !didStartInitialLoad else { return }
        didStartInitialLoad = true

        startFPSCounter()

        // Load far image and prepare colour engine chroma texture in parallel
        async let far = loadFarImage()
        async let chromaPrep: Void = withCheckedContinuation { continuation in
            processingQueue.async {
                ColourEngine.shared.prepareChromaTexture()
                continuation.resume()
            }
        }
        farImage = await far
        await chromaPrep

        let isPrebaked = TerrainAssetPaths.currentSource == .prebaked
        let allDescriptors = CTXTileLoader.rawTiles(intersecting: PathfinderExperience.worldRect, skipFileCheck: isPrebaked)
        let cachedCount = await loadCachedTiles(allDescriptors)
        if cachedCount == allDescriptors.count && cachedCount > 0 {
            totalLevel1TileCount = cachedCount
            level1CompletedCount = cachedCount
            allLevel1Preloaded = true
            if colourMode {
                await compositeReadyTiles()
            }
        } else {
            if cachedCount > 0 {
                level1Tiles.removeAll()
            }
            startPreEnhancement()
        }
    }

    func setColourMode(_ on: Bool) {
        guard colourMode != on else { return }
        colourMode = on
        // Keep colourised cache — don't clear on toggle off.
        // displayImageForL1 checks colourMode to decide which to return.
        // If cache is empty (first toggle on), build it.
        if on && colourisedL1Cache.isEmpty {
            Task { [weak self] in await self?.compositeReadyTiles() }
        }
        // Tier 3: activeTier3Mosaic computed property swaps instantly
        objectWillChange.send()
    }

    func displayImageForL1(_ tileID: String) -> CGImage? {
        let bwSource: CGImage?
        if showRawTiles, let raw = rawL1Cache[tileID] {
            bwSource = raw
        } else if let tile = level1Tiles[tileID], case .ready(let bw) = tile.phase {
            bwSource = bw
        } else {
            return nil
        }
        if colourMode, let colourised = colourisedL1Cache[tileID] { return colourised }
        return bwSource
    }

    func toggleRawTiles() {
        showRawTiles.toggle()
        // Rebuild colourised cache from the new B&W source without clearing the old cache first.
        if colourMode {
            Task { [weak self] in await self?.compositeReadyTiles() }
        }
        // Tier 2 & 3: activeTier2Strips/activeTier3Mosaic computed properties swap instantly
        objectWillChange.send()
    }


    // MARK: - Per-tile disk cache

    private nonisolated static let cacheDirectory: URL = {
        TerrainAssetPaths.localLevel1EnhancedDirectory.deletingLastPathComponent()
    }()

    private nonisolated static let tileCacheDirectory: URL = {
        TerrainAssetPaths.localLevel1EnhancedDirectory
    }()

    private nonisolated static let rawTileCacheDirectory: URL = {
        TerrainAssetPaths.localLevel1RawDirectory
    }()

    private nonisolated static func tileCacheURL(for name: String) -> URL {
        tileCacheDirectory.appendingPathComponent("\(name).jpg")
    }

    private nonisolated static func rawTileCacheURL(for name: String) -> URL {
        rawTileCacheDirectory.appendingPathComponent("\(name).jpg")
    }

    private nonisolated static func loadCachedImage(at url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }

    private nonisolated static func saveTierCache(image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func loadCachedTiles(_ descriptors: [CTXRawTileDescriptor]) async -> Int {
        let enhancedDirectory = TerrainAssetPaths.level1EnhancedDirectory()
        let rawDirectory = TerrainAssetPaths.level1RawDirectory()
        var loaded = 0
        var rawLoaded = 0
        for descriptor in descriptors {
            guard let enhancedDirectory else { break }
            let url = enhancedDirectory.appendingPathComponent("\(descriptor.name).jpg")
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }

            level1Tiles[descriptor.id] = Level1TileRenderState(
                descriptor: descriptor,
                phase: .ready(image),
                elapsedMs: nil,
                lastAccess: Date()
            )
            loaded += 1

            // Also load the raw (unenhanced) version if cached
            let rawURL = rawDirectory?.appendingPathComponent("\(descriptor.name).jpg")
            if let rawURL,
               FileManager.default.fileExists(atPath: rawURL.path),
               let rawSource = CGImageSourceCreateWithURL(rawURL as CFURL, nil),
               let rawImage = CGImageSourceCreateImageAtIndex(rawSource, 0, nil) {
                rawL1Cache[descriptor.id] = rawImage
                rawLoaded += 1
            }
        }
        return loaded
    }

    private nonisolated static func saveTileToCache(name: String, image: CGImage) {
        let dir = tileCacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = tileCacheURL(for: name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private nonisolated static func saveRawTileToCache(name: String, image: CGImage) {
        let dir = rawTileCacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = rawTileCacheURL(for: name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private static func deleteAllCachedTiles() {
        TerrainAssetPaths.clearLocalRenderedData()
    }

    private func startFPSCounter() {
        let target = FPSDisplayLinkTarget()
        target.onFPS = { [weak self] fps in
            Task { @MainActor in
                self?.fps = fps
                self?.memoryMB = Self.currentMemoryMB()
                if let self, self.isEnhancing, self.enhancementStartTime > 0 {
                    self.enhancementElapsedSeconds = CFAbsoluteTimeGetCurrent() - self.enhancementStartTime
                }
            }
        }
        target.start()
        fpsTarget = target
    }

    private func startPreEnhancement() {
        let allDescriptors = CTXTileLoader.rawTiles(intersecting: PathfinderExperience.worldRect)
        totalLevel1TileCount = allDescriptors.count

        guard !allDescriptors.isEmpty else {
            allLevel1Preloaded = true
            return
        }

        isEnhancing = true
        enhancementStartTime = CFAbsoluteTimeGetCurrent()

        for descriptor in allDescriptors {
            level1Tiles[descriptor.id] = Level1TileRenderState(
                descriptor: descriptor,
                phase: .loading,
                elapsedMs: nil,
                lastAccess: Date()
            )
        }

        Task { [weak self] in
            guard let self else { return }
            for descriptor in allDescriptors {
                if Task.isCancelled {
                    break
                }
                await self.loadLevel1Tile(descriptor)
                self.onLevel1TileCompleted(descriptor)
            }
        }
    }

    private func onLevel1TileCompleted(_ descriptor: CTXRawTileDescriptor) {
        level1CompletedCount += 1

        if let tile = level1Tiles[descriptor.id], let ms = tile.elapsedMs {
            totalInferenceMs += ms
        }

        if level1CompletedCount >= totalLevel1TileCount {
            enhancementElapsedSeconds = CFAbsoluteTimeGetCurrent() - enhancementStartTime
            VikingMosaicProvider.releaseCache()
            allLevel1Preloaded = true
            isEnhancing = false
            if colourMode {
                Task { [weak self] in await self?.compositeReadyTiles() }
            }
        }
    }

    private static func currentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / (1024 * 1024)) : 0
    }

    func updateVisibleLevel1Tiles(for visibleRect: GeoRect) {
        guard !allLevel1Preloaded, !isEnhancing else { return }
        let neededDescriptors = CTXTileLoader.rawTiles(intersecting: prefetchedRect(for: visibleRect))

        for descriptor in neededDescriptors {
            if var existing = level1Tiles[descriptor.id] {
                existing.lastAccess = Date()
                level1Tiles[descriptor.id] = existing
                continue
            }

            level1Tiles[descriptor.id] = Level1TileRenderState(
                descriptor: descriptor,
                phase: .loading,
                elapsedMs: nil,
                lastAccess: Date()
            )

            level1LoadTasks[descriptor.id] = Task { [weak self] in
                await self?.loadLevel1Tile(descriptor)
            }
        }
    }

    private func loadFarImage() async -> CGImage? {
        await withCheckedContinuation { continuation in
            processingQueue.async {
                let image = VikingMosaicProvider.crop(
                    rect: PathfinderExperience.farRect,
                    targetWidth: PathfinderExperience.farImageWidth
                )
                continuation.resume(returning: image)
            }
        }
    }

    private func loadLevel1Tile(_ rawTile: CTXRawTileDescriptor) async {
        let sourceImage = await withCheckedContinuation { continuation in
            processingQueue.async {
                continuation.resume(returning: CTXTileLoader.loadLevel1Image(
                    for: rawTile
                ))
            }
        }

        guard let sourceImage, !Task.isCancelled else {
            if var existing = level1Tiles[rawTile.id] {
                existing.phase = .failed
                level1Tiles[rawTile.id] = existing
            }
            level1LoadTasks[rawTile.id] = nil
            return
        }

        // Use source image at native resolution — no downsampling needed.
        // Convert to grayscale for consistent display.
        let rawResized = await withCheckedContinuation { continuation in
            processingQueue.async {
                let grayscale = TileManager.resizeImage(
                    sourceImage,
                    to: CGSize(width: sourceImage.width, height: sourceImage.height),
                    grayscale: true
                )
                continuation.resume(returning: grayscale)
            }
        }
        if let rawResized {
            rawL1Cache[rawTile.id] = rawResized
            // Show the raw tile immediately while enhancement runs
            if var existing = level1Tiles[rawTile.id] {
                existing.phase = .ready(rawResized)
                existing.lastAccess = Date()
                level1Tiles[rawTile.id] = existing
            }
            if colourMode {
                await compositeSingleTile(id: rawTile.id, bwImage: rawResized, geoRect: rawTile.geoRect)
            }
        }

        // Level 1 enhancement skipped — raw tile is the final output
        level1LoadTasks[rawTile.id] = nil
    }

    // MARK: - Tier 2 pre-built strips

    func loadTier2Strips() {
        guard !tier2Loaded else { return }
        tier2Loaded = true
        Task { [weak self] in
            guard let self else { return }
            // Load variants sequentially to avoid exhausting the IOSurface pool
            let eb = await withCheckedContinuation { (c: CheckedContinuation<[IndexedStrip], Never>) in
                self.processingQueue.async { c.resume(returning: Self.loadStrips(prefix: "tier2_enhanced")) }
            }
            let ec = await withCheckedContinuation { (c: CheckedContinuation<[IndexedStrip], Never>) in
                self.processingQueue.async { c.resume(returning: Self.loadStrips(prefix: "tier2_enhanced_colour")) }
            }
            let rb = await withCheckedContinuation { (c: CheckedContinuation<[IndexedStrip], Never>) in
                self.processingQueue.async { c.resume(returning: Self.loadStrips(prefix: "tier2_raw")) }
            }
            let rc = await withCheckedContinuation { (c: CheckedContinuation<[IndexedStrip], Never>) in
                self.processingQueue.async { c.resume(returning: Self.loadStrips(prefix: "tier2_raw_colour")) }
            }

            self.tier2EnhancedBW = eb
            self.tier2EnhancedColour = ec
            self.tier2RawBW = rb
            self.tier2RawColour = rc
            self.tier2Ready = !self.activeTier2Strips.isEmpty

        }
    }

    private nonisolated static func loadStrips(prefix: String) -> [IndexedStrip] {
        guard let directory = TerrainAssetPaths.tier2StripDirectory() else { return [] }
        var strips: [IndexedStrip] = []
        for i in 0..<tier2StripCount {
            let url = directory.appendingPathComponent("\(prefix)_strip\(i).jpg")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                continue
            }
            strips.append(IndexedStrip(index: i, image: image))
        }
        return strips
    }

    nonisolated static func geoRectForStrip(index: Int, rowsPerStrip: Int) -> GeoRect {
        let stripLatMax = HiRISETier2Loader.latMax - Double(index * rowsPerStrip) * HiRISETier2Loader.degreesPerTileLat
        let stripLatMin = HiRISETier2Loader.latMax - Double((index + 1) * rowsPerStrip) * HiRISETier2Loader.degreesPerTileLat
        return GeoRect(
            lonMin: HiRISETier2Loader.lonMin,
            lonMax: HiRISETier2Loader.lonMax,
            latMin: stripLatMin,
            latMax: stripLatMax
        )
    }

    // MARK: - Tier 3 pre-built mosaic

    /// Geo rect of the actual tier 3 mosaic (tile-aligned)
    nonisolated static let tier3MosaicRect: GeoRect = {
        let dLat = (HiRISETileLoader.latMax - HiRISETileLoader.latMin) / Double(HiRISETileLoader.gridRows)
        let dLon = (HiRISETileLoader.lonMax - HiRISETileLoader.lonMin) / Double(HiRISETileLoader.gridCols)
        return GeoRect(
            lonMin: HiRISETileLoader.lonMin + Double(tier3SourceColStart) * dLon,
            lonMax: HiRISETileLoader.lonMin + Double(tier3SourceColEnd + 1) * dLon,
            latMin: HiRISETileLoader.latMax - Double(tier3SourceRowEnd + 1) * dLat,
            latMax: HiRISETileLoader.latMax - Double(tier3SourceRowStart) * dLat
        )
    }()

    func loadTier3Strips() {
        guard !tier3Loaded else { return }
        tier3Loaded = true
        Task { [weak self] in
            guard let self else { return }
            // Load strip sets sequentially to avoid exhausting the IOSurface pool
            let ebM = await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
                self.processingQueue.async {
                    let strips = Self.loadTier3StripSet(prefix: "tier3_enhanced")
                    c.resume(returning: Self.compositeTier3Mosaic(from: strips))
                }
            }
            let ecM = await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
                self.processingQueue.async {
                    let strips = Self.loadTier3StripSet(prefix: "tier3_enhanced_colour")
                    c.resume(returning: Self.compositeTier3Mosaic(from: strips))
                }
            }
            let rbM = await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
                self.processingQueue.async {
                    let strips = Self.loadTier3StripSet(prefix: "tier3_raw")
                    c.resume(returning: Self.compositeTier3Mosaic(from: strips))
                }
            }
            let rcM = await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
                self.processingQueue.async {
                    let strips = Self.loadTier3StripSet(prefix: "tier3_raw_colour")
                    c.resume(returning: Self.compositeTier3Mosaic(from: strips))
                }
            }

            self.tier3EnhancedBWMosaic = ebM
            self.tier3EnhancedColourMosaic = ecM
            self.tier3RawBWMosaic = rbM
            self.tier3RawColourMosaic = rcM
            self.tier3Ready = self.activeTier3Mosaic != nil

        }
    }

    private nonisolated static func loadTier3StripSet(prefix: String) -> [IndexedStrip] {
        guard let directory = TerrainAssetPaths.tier3StripDirectory() else { return [] }
        var strips: [IndexedStrip] = []
        for i in 0..<tier3StripCount {
            let url = directory.appendingPathComponent("\(prefix)_strip\(i).jpg")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                continue
            }
            strips.append(IndexedStrip(index: i, image: image))
        }
        return strips
    }

    /// Composite column-based strips into a single mosaic image.
    /// Caps width at 16384 (Metal texture limit) and downscales proportionally if needed.
    private nonisolated static func compositeTier3Mosaic(from strips: [IndexedStrip]) -> CGImage? {
        guard !strips.isEmpty else { return nil }
        let sorted = strips.sorted { $0.index < $1.index }
        let stripW = sorted[0].image.width
        let stripH = sorted[0].image.height
        let totalW = stripW * sorted.count

        let maxTextureSize = 16384
        let needsScale = totalW > maxTextureSize
        let targetW = needsScale ? maxTextureSize : totalW
        let targetH = needsScale ? stripH * maxTextureSize / totalW : stripH

        let isColor = sorted[0].image.bitsPerPixel > 8
        let colorSpace = isColor
            ? (sorted[0].image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
            : CGColorSpaceCreateDeviceGray()
        let bytesPerPixel = isColor ? 4 : 1
        let bitmapInfo = isColor
            ? CGImageAlphaInfo.noneSkipLast.rawValue
            : CGImageAlphaInfo.none.rawValue

        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * bytesPerPixel,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = .high

        for (i, strip) in sorted.enumerated() {
            let x0 = i * targetW / sorted.count
            let x1 = (i + 1) * targetW / sorted.count
            context.draw(strip.image, in: CGRect(x: x0, y: 0, width: x1 - x0, height: targetH))
        }

        return context.makeImage()
    }

    // MARK: - Colour compositing

    private func compositeReadyTiles() async {
        let engine = ColourEngine.shared
        let tiles: [(String, CGImage, GeoRect)] = level1Tiles.compactMap { (id, tile) in
            guard colourisedL1Cache[id] == nil else { return nil }
            let bw: CGImage?
            if showRawTiles, let raw = rawL1Cache[id] {
                bw = raw
            } else if case .ready(let img) = tile.phase {
                bw = img
            } else {
                bw = nil
            }
            guard let bw else { return nil }
            return (id, bw, tile.descriptor.geoRect)
        }
        guard !tiles.isEmpty else { return }

        let results = await withCheckedContinuation { (continuation: CheckedContinuation<[(String, CGImage)], Never>) in
            processingQueue.async {
                engine.prepareChromaTexture()
                var out: [(String, CGImage)] = []
                for (id, bw, rect) in tiles {
                    if let c = engine.composite(luminanceTile: bw, tileRect: rect) {
                        out.append((id, c))
                    }
                }
                continuation.resume(returning: out)
            }
        }

        var updated = colourisedL1Cache
        for (id, img) in results {
            updated[id] = img
        }
        colourisedL1Cache = updated
    }

    private func compositeSingleTile(id: String, bwImage: CGImage, geoRect: GeoRect) async {
        let engine = ColourEngine.shared
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            processingQueue.async {
                engine.prepareChromaTexture()
                let composite = engine.composite(luminanceTile: bwImage, tileRect: geoRect)
                continuation.resume(returning: composite)
            }
        }
        if let result {
            colourisedL1Cache[id] = result
        }
    }

    private func distanceSquared(from lhs: MarsCoordinate, to rhs: MarsCoordinate) -> Double {
        let dx = lhs.lon - rhs.lon
        let dy = lhs.lat - rhs.lat
        return dx * dx + dy * dy
    }

    private func prefetchedRect(for visibleRect: GeoRect) -> GeoRect {
        let lonInset = CTXTileLoader.degreesPerRaw * 0.5
        let latInset = CTXTileLoader.degreesPerRaw * 0.5

        return GeoRect(
            lonMin: max(PathfinderExperience.worldRect.lonMin, visibleRect.lonMin - lonInset),
            lonMax: min(PathfinderExperience.worldRect.lonMax, visibleRect.lonMax + lonInset),
            latMin: max(PathfinderExperience.worldRect.latMin, visibleRect.latMin - latInset),
            latMax: min(PathfinderExperience.worldRect.latMax, visibleRect.latMax + latInset)
        )
    }
}

struct SampleSizeView: View {
    @Binding var colourMode: Bool
    @Binding var showPOI: Bool
    @Binding var showEnhance: Bool
    @Binding var showTelemetry: Bool
    @Binding var showCTX: Bool
    @Binding var showAltimeter: Bool
    var isFullScreen: Bool = false
    @Binding var scale: CGFloat
    @Binding var offset: CGSize

    @AppStorage("useImperialUnits") private var useImperialUnits = false
    @AppStorage("showSettings") private var showSettings = false

    @StateObject private var model = PathfinderExplorerModel()
    @StateObject private var timekeeper = MarsTimekeeper()
    @State private var dragStartOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var cursorPoint: CGPoint?
    @State private var settledScale: CGFloat = 1.0
    @State private var settledOffset: CGSize = .zero
    @State private var settleTask: Task<Void, Never>?
    @State private var ctxAlwaysMode: Bool = true
    @State private var placedMarkers: [MarsCoordinate] = []
    @State private var draggingMarkerIndex: Int?
    @State private var dragStartScreenPos: CGPoint?
    @AppStorage("markerMode") private var markerMode = false
    @AppStorage("tier3OffsetLon") private var tier3OffsetLon: Double = 0
    @AppStorage("tier3OffsetLat") private var tier3OffsetLat: Double = 0
    @State private var tier3DragStart: CGPoint?
    @State private var tier3DebugOpacity: Double = 1.0
    @State private var hasSetInitialScale = false
    var body: some View {
        GeometryReader { geometry in
            let viewportSize = geometry.size

            // Settled state: used only for tile loading task key (avoids task churn during gestures)
            let settledRect = visibleGeoRect(forScale: settledScale, offset: settledOffset, viewportSize: viewportSize)
            let settledWidthKmForT2 = settledRect.width * PathfinderExperience.kmPerDegreeLon(at: settledRect.center.lat)
            let settledL2Opacity = PathfinderExperience.tier2Enabled && PathfinderExperience.hiriseTier2CoverageRect.intersects(settledRect)
                ? tierOpacity(for: settledWidthKmForT2, start: PathfinderExperience.tier2StartKm, end: PathfinderExperience.tier2EndKm)
                : 0.0
            let visibleTileBudget = PathfinderExperience.tier2Enabled && settledL2Opacity > 0.02
                ? PathfinderExperience.maxVisibleLevel2Tiles
                : 0

            // Tier 3 settled: only load when viewport centre is within HiRISE coverage
            let settledWidthKm = settledRect.width * PathfinderExperience.kmPerDegreeLon(at: settledRect.center.lat)
            let settledL3Opacity = PathfinderExperience.tier3CropRect.intersects(settledRect)
                ? tierOpacity(for: settledWidthKm, start: PathfinderExperience.tier3StartKm, end: PathfinderExperience.tier3EndKm)
                : 0.0
            let visibleLevel3Budget = settledL3Opacity > 0.02
                ? PathfinderExperience.maxVisibleLevel3Tiles
                : 0

            // Live state: for overlays and content opacity
            let liveRect = visibleGeoRect(forScale: scale, offset: offset, viewportSize: viewportSize)
            let liveWidthKm = liveRect.width * PathfinderExperience.kmPerDegreeLon(at: liveRect.center.lat)

            // CTX opacity depends on mode:
            // Mode 1 (crossfade): ease-out cubic scale=1→0%, scale=9→100%
            // Mode 2 (CTX-always): 100% at all zoom levels
            let liveL1Opacity = ctxL1Opacity(for: scale)

            // Tier 2/3 opacity: only show when tiles exist AND viewport is close enough
            let hasT2Mosaic = !model.activeTier2Strips.isEmpty
            let liveL2Opacity = PathfinderExperience.tier2Enabled && hasT2Mosaic && PathfinderExperience.hiriseTier2CoverageRect.intersects(liveRect)
                ? tierOpacity(for: liveWidthKm, start: PathfinderExperience.tier2StartKm, end: PathfinderExperience.tier2EndKm)
                : 0.0

            let hasT3Mosaic = model.activeTier3Mosaic != nil
            let liveL3Opacity = PathfinderExperience.tier3Enabled && hasT3Mosaic && PathfinderExperience.tier3CropRect.intersects(liveRect)
                ? tierOpacity(for: liveWidthKm, start: PathfinderExperience.tier3StartKm, end: PathfinderExperience.tier3EndKm)
                : 0.0

            let focusCoordinate = coordinate(at: cursorPoint ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2), viewportSize: viewportSize)

            ZStack {
                viewportContent(viewportSize: viewportSize, level1Opacity: liveL1Opacity, level2Opacity: liveL2Opacity, level3Opacity: liveL3Opacity)

                viewportOverlays(
                    viewportSize: viewportSize,
                    focusCoordinate: focusCoordinate,
                    visibleWidthKm: liveWidthKm,
                    level1Opacity: liveL1Opacity,
                    level2Opacity: liveL2Opacity,
                    level3Opacity: liveL3Opacity
                )


                // Left edge gradient for legibility on bright tiles
                if showCTX {
                    HStack(spacing: 0) {
                        LinearGradient(
                            colors: [.black.opacity(0.5), .black.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 200)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                // Left column: region title + comparable altitude (non-interactive)
                GeometryReader { leftGeo in
                    let heightKm = altitudeHeightKm(liveRect: liveRect)
                    let altKm = heightKm / 1.15
                    let titleHeight: CGFloat = 30

                    let regionTitle = liveL3Opacity > 0.8
                        ? "Pathfinder Landing Site"
                        : liveL2Opacity > 0.5
                            ? "Ares Vallis"
                            : "Chryse Planitia"

                    VStack(alignment: .leading, spacing: 0) {
                        Text(regionTitle)
                            .font(.blender(.medium, size: 26))
                            .foregroundStyle(.white.opacity(0.94))
                            .frame(height: titleHeight, alignment: .topLeading)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.2), value: regionTitle)

                        Spacer().frame(height: 16)

                        if showAltimeter {
                            Spacer()

                            VStack(alignment: .leading, spacing: 3) {
                                Text("COMPARABLE ALTITUDE")
                                    .font(.blender(.medium, size: 13))
                                    .foregroundStyle(.white)

                                Text(AltitudeScaleBar.comparableAltitude(altKm))
                                    .font(.blender(.medium, size: 13))
                                    .foregroundStyle(.white)
                                    .contentTransition(.numericText())
                                    .animation(.easeOut(duration: 0.2), value: AltitudeScaleBar.comparableAltitude(altKm))
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.35), value: showAltimeter)
                    .padding(16)
                }
                .allowsHitTesting(false)

                // Telemetry panel overlay
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if showTelemetry {
                            let cursorCoord = coordinate(at: cursorPoint ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2), viewportSize: viewportSize)
                            let coordStr = showSettings ? "—" : String(format: "%.2f°N, %.2f°E", cursorCoord.lat, cursorCoord.lon)
                            let resStr = telemetryResolution(widthKm: liveWidthKm, viewportWidth: viewportSize.width)
                            let fovStr = telemetryFieldOfView(viewportSize: viewportSize)

                            TelemetryView(
                                timekeeper: timekeeper,
                                coordinates: coordStr,
                                resolution: resStr,
                                fieldOfView: fovStr,
                                enhanceEnabled: showEnhance
                            )
                            .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                        }
                    }
                }
                .padding(8)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showTelemetry)

            }
            .contentShape(Rectangle())
            .overlay {
                if !markerMode {
                    ViewportInteractionLayer(
                        cursorPoint: $cursorPoint,
                        onScroll: { event in
                            if event.hasPreciseScrollingDeltas && !event.modifierFlags.intersection([.command, .option]).isEmpty {
                                let anchor = cursorPoint ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
                                let zoomDelta = pow(1.0012, -event.scrollingDeltaY)
                                zoom(
                                    to: scale * CGFloat(zoomDelta),
                                    anchor: anchor,
                                    viewportSize: viewportSize,
                                    animated: false
                                )
                            } else if event.hasPreciseScrollingDeltas {
                                pan(
                                    by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                                    viewportSize: viewportSize
                                )
                            } else {
                                let anchor = cursorPoint ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
                                let zoomDelta = pow(1.0012, -event.scrollingDeltaY)
                                zoom(
                                    to: scale * CGFloat(zoomDelta),
                                    anchor: anchor,
                                    viewportSize: viewportSize,
                                    animated: true
                                )
                            }
                        },
                        onMagnify: { magnification, location in
                            let anchor = location ?? cursorPoint ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
                            zoom(
                                to: scale * max(0.25, 1 + magnification),
                                anchor: anchor,
                                viewportSize: viewportSize
                            )
                        },
                        onDragChanged: { translation in
                            updateDrag(translation: translation, viewportSize: viewportSize)
                        },
                        onDragEnded: { translation, velocity in
                            finishDrag(translation: translation, velocity: velocity, viewportSize: viewportSize)
                        },
                        onClick: { point in
                            guard markerMode else { return }
                            let coord = coordinate(at: point, viewportSize: viewportSize)
                            if placedMarkers.count < 5 {
                                placedMarkers.append(coord)
                                let i = placedMarkers.count
                                print("[Marker \(i)] MarsCoordinate(lat: \(coord.lat), lon: \(coord.lon))")
                            }
                        },
                        onOptionDrag: { point in
                            let coord = coordinate(at: point, viewportSize: viewportSize)
                            if let idx = draggingMarkerIndex ?? nearestMarkerIndex(to: point, viewportSize: viewportSize) {
                                draggingMarkerIndex = idx
                                placedMarkers[idx] = coord
                            }
                        },
                        onOptionDragEnd: {
                            if let idx = draggingMarkerIndex {
                                let coord = placedMarkers[idx]
                                print("[Marker \(idx + 1)] MarsCoordinate(lat: \(coord.lat), lon: \(coord.lon))")
                            }
                            draggingMarkerIndex = nil
                        }
                    )
                }
                }
            .overlay(alignment: .topLeading) {
                if showAltimeter {
                    let heightKm = altitudeHeightKm(liveRect: liveRect)
                    let titleHeight: CGFloat = 30
                    let compHeight: CGFloat = 36
                    let barHeight = max(viewportSize.height - 16 - titleHeight - 16 - 24 - compHeight - 16, 100)

                    AltitudeScaleBar(
                        trackHeight: barHeight,
                        visibleHeightKm: heightKm,
                        minScale: PathfinderExperience.minZoomScale(for: viewportSize),
                        maxScale: PathfinderExperience.maxZoomScale,
                        currentScale: scale,
                        onScaleChange: { newScale, animated in
                            zoom(to: newScale, anchor: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2), viewportSize: viewportSize, animated: animated)
                        }
                    )
                    .padding(.top, 16 + titleHeight + 16)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                    .animation(.easeInOut(duration: 0.35), value: showAltimeter)
                }
            }
            .task {
                model.setColourMode(colourMode)
                if showEnhance != !model.showRawTiles {
                    model.toggleRawTiles()
                }
                await model.loadInitialAssets()
            }
            .task(id: tileRequestKey(for: settledRect, scale: settledScale, visibleTileBudget: visibleTileBudget, level3Budget: visibleLevel3Budget)) {
                model.updateVisibleLevel1Tiles(for: settledRect)
            }
            .task(id: Int(scale * 10)) {
                // Load pre-built Tier 2 strips as soon as user zooms in
                if PathfinderExperience.tier2Enabled && model.allLevel1Preloaded && scale > 2 {
                    model.loadTier2Strips()
                }
                if PathfinderExperience.tier3Enabled && model.tier2Ready && scale > 2 {
                    model.loadTier3Strips()
                }
            }
.onKeyPress(.init("a"), phases: .down) { _ in
                showAltimeter.toggle()
                return .handled
            }
            .onKeyPress(.init("p"), phases: .down) { _ in
                showPOI.toggle()
                return .handled
            }
            .onKeyPress(.init("t"), phases: .down) { _ in
                showTelemetry.toggle()
                return .handled
            }
            .onKeyPress(.init("c"), phases: .down) { _ in
                colourMode.toggle()
                return .handled
            }
            .onKeyPress(.init("u"), phases: .down) { _ in
                showEnhance.toggle()
                return .handled
            }
            .onChange(of: colourMode) { _, newValue in
                model.setColourMode(newValue)
            }
            .onChange(of: showEnhance) { _, newValue in
                if newValue != !model.showRawTiles {
                    model.toggleRawTiles()
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                let minScale = PathfinderExperience.minZoomScale(for: newSize)
                if scale < minScale {
                    scale = minScale
                    settledScale = minScale
                }
            }
        }
    }

    private func viewportContent(viewportSize: CGSize, level1Opacity: Double, level2Opacity: Double, level3Opacity: Double) -> some View {
        return ZStack {
            Color.black

            ZStack {
                let tier2CoverageFrame = baseFrame(for: PathfinderExperience.hiriseTier2CoverageRect, viewportSize: viewportSize)
                let tier3CutoutFrame = baseFrame(for: PathfinderExplorerModel.tier3MosaicRect, viewportSize: viewportSize)

                ZStack {
                    if !showCTX, let farImage = model.farImage {
                        imageLayer(
                            farImage,
                            frame: baseFrame(for: PathfinderExperience.farRect, viewportSize: viewportSize),
                            interpolation: .high
                        )
                    }

                    if showCTX, level1Opacity > 0 {
                        ForEach(model.orderedLevel1Tiles) { tile in
                            level1TileLayer(tile, viewportSize: viewportSize, opacity: level1Opacity)
                        }
                    }
                }
                .modifier(TierCutoutMask(
                    isActive: level2Opacity > 0 && !model.activeTier2Strips.isEmpty,
                    cutoutFrame: tier2CoverageFrame,
                    cutoutOpacity: level2Opacity
                ))

                if PathfinderExperience.tier2Enabled && level2Opacity > 0 && !model.activeTier2Strips.isEmpty {
                    let rowsPerStrip = HiRISETier2Loader.gridRows / PathfinderExplorerModel.tier2StripCount
                    let interp: Image.Interpolation = model.showRawTiles ? .none : .high

                    ZStack {
                        ForEach(model.activeTier2Strips) { strip in
                            let stripRect = PathfinderExplorerModel.geoRectForStrip(index: strip.index, rowsPerStrip: rowsPerStrip)
                            imageLayer(strip.image, frame: baseFrame(for: stripRect, viewportSize: viewportSize), interpolation: interp)
                        }
                    }
                    .opacity(level2Opacity)
                }

                // POI overlays: white preview fill + border + pinned labels
                if showPOI {
                    let t2WhiteOpacity = 0.12 * (1 - level2Opacity)
                    let t3WhiteOpacity = 0.0

                    Rectangle()
                        .fill(.white.opacity(t2WhiteOpacity))
                        .overlay(Rectangle().strokeBorder(.white.opacity(0.6), lineWidth: 2 / scale))
                        .overlay(alignment: .topTrailing) {
                            tierLabel("ARES VALLIS", rect: PathfinderExperience.hiriseTier2CoverageRect, titleSize: 11, detailSize: 9)
                                .alignmentGuide(.trailing) { d in d[.leading] }
                                .scaleEffect(max(1 / scale, 0.03), anchor: .topLeading)
                        }
                        .frame(width: tier2CoverageFrame.width, height: tier2CoverageFrame.height)
                        .position(x: tier2CoverageFrame.midX, y: tier2CoverageFrame.midY)
                        .allowsHitTesting(false)

                    // Tier 3 border + label rendered in screen space (below) alongside mosaic
                }
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .scaleEffect(scale, anchor: .center)
            .offset(offset)

            // Tier 3 mosaic + border + label in screen space — avoids sub-pixel base-frame distortion
            if level2Opacity > 0.5 || level3Opacity > 0 {
                let ppp = 1.0 / PathfinderExperience.baseDegreesPerPoint(for: viewportSize)
                let rect = PathfinderExplorerModel.tier3MosaicRect
                let adjustedCenter = MarsCoordinate(
                    lat: rect.center.lat + tier3OffsetLat,
                    lon: rect.center.lon + tier3OffsetLon
                )
                let center = screenPosition(for: adjustedCenter, viewportSize: viewportSize)
                let screenW = CGFloat(rect.width * ppp) * scale

                if let tier3Mosaic = model.activeTier3Mosaic {
                    let imgAspect = CGFloat(tier3Mosaic.width) / CGFloat(tier3Mosaic.height)
                    let screenH = screenW / imgAspect
                    let interp3: Image.Interpolation = model.showRawTiles ? .none : .high
                    Image(nsImage: NSImage(cgImage: tier3Mosaic, size: NSSize(width: tier3Mosaic.width, height: tier3Mosaic.height)))
                        .resizable()
                        .interpolation(interp3)
                        .frame(width: screenW, height: screenH)
                        .position(center)
                        .opacity(level3Opacity)
                        .allowsHitTesting(false)
                }

                if showPOI {
                    let screenH = screenW / 1.5  // match mosaic aspect
                    let t3StrokeOpacity = level3Opacity > 0 ? max(0.6, level3Opacity * 0.9) : 0.6
                    Rectangle()
                        .strokeBorder(.white.opacity(t3StrokeOpacity), lineWidth: 2)
                        .frame(width: screenW, height: screenH)
                        .position(center)
                        .allowsHitTesting(false)

                    // PATHFINDER LANDING SITE label
                    let topRight = CGPoint(x: center.x + screenW / 2, y: center.y - screenH / 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PATHFINDER LANDING SITE")
                            .font(.blender(.medium, size: 13))
                            .foregroundStyle(.white)
                        let widthKm = rect.width * PathfinderExperience.kmPerDegreeLon(at: rect.center.lat)
                        let heightKm = rect.height * PathfinderExperience.kmPerDegreeLat
                        Text(String(format: "%.1f × %.1f KM", widthKm, heightKm))
                            .font(.blender(.medium, size: 10))
                            .foregroundStyle(.white)
                        Text(String(format: "%.1f KM²", widthKm * heightKm))
                            .font(.blender(.medium, size: 10))
                            .foregroundStyle(.white)
                    }
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.black)
                    .position(x: topRight.x + 60, y: topRight.y + 30)
                    .allowsHitTesting(false)
                }
            }

            if showPOI && level3Opacity > 0.1 {
                ForEach(Array(PathfinderExperience.pointsOfInterest.enumerated()), id: \.offset) { _, poi in
                    let pos = screenPosition(for: poi.coordinate, viewportSize: viewportSize)
                    poiCallout(name: poi.name, at: pos, viewportSize: viewportSize)
                        .opacity(level3Opacity)
                        .allowsHitTesting(false)
                }
            }

            // Dev marker tool: toggle disables pan/zoom, click to place, drag labels to move
            if markerMode {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let coord = coordinate(at: location, viewportSize: viewportSize)
                        if placedMarkers.count < 5 {
                            placedMarkers.append(coord)
                            print("[Marker \(placedMarkers.count)] MarsCoordinate(lat: \(coord.lat), lon: \(coord.lon))")
                        }
                    }
            }

            // Marker crosshairs + draggable labels
            let markerColors: [Color] = [.red, .green, .cyan, .yellow, .orange]
            ZStack {
                ForEach(Array(placedMarkers.enumerated()), id: \.offset) { i, marker in
                    let pos = screenPosition(for: marker, viewportSize: viewportSize)
                    let color = markerColors[i % markerColors.count]
                    Path { p in
                        p.move(to: CGPoint(x: pos.x - 8, y: pos.y))
                        p.addLine(to: CGPoint(x: pos.x + 8, y: pos.y))
                        p.move(to: CGPoint(x: pos.x, y: pos.y - 8))
                        p.addLine(to: CGPoint(x: pos.x, y: pos.y + 8))
                    }
                    .stroke(color, lineWidth: 1.5)
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .frame(width: 12, height: 12)
                        .position(pos)
                }
            }
            .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
            .allowsHitTesting(false)

            if markerMode {
                ForEach(Array(placedMarkers.enumerated()), id: \.offset) { i, marker in
                    let pos = screenPosition(for: marker, viewportSize: viewportSize)
                    let color = markerColors[i % markerColors.count]
                    Text(String(format: "Marker %d\nlat: %.6f\nlon: %.6f", i + 1, marker.lat, marker.lon))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(color)
                        .padding(4)
                        .background(.black.opacity(0.8))
                        .fixedSize()
                        .offset(x: pos.x + 70 - viewportSize.width / 2, y: pos.y - 24 - viewportSize.height / 2)
                        .gesture(
                            DragGesture(coordinateSpace: .global)
                                .onChanged { value in
                                    if dragStartScreenPos == nil {
                                        dragStartScreenPos = pos
                                        draggingMarkerIndex = i
                                    }
                                    if let start = dragStartScreenPos {
                                        let newPos = CGPoint(
                                            x: start.x + value.translation.width,
                                            y: start.y + value.translation.height
                                        )
                                        placedMarkers[i] = coordinate(at: newPos, viewportSize: viewportSize)
                                    }
                                }
                                .onEnded { _ in
                                    let coord = placedMarkers[i]
                                    print("[Marker \(i + 1)] MarsCoordinate(lat: \(coord.lat), lon: \(coord.lon))")
                                    dragStartScreenPos = nil
                                    draggingMarkerIndex = nil
                                }
                        )
                        .frame(width: viewportSize.width, height: viewportSize.height)
                }
            }

        }
    }

    private func tierLabel(_ title: String, rect: GeoRect, titleSize: CGFloat, detailSize: CGFloat) -> some View {
        let widthKm = rect.width * PathfinderExperience.kmPerDegreeLon(at: rect.center.lat)
        let heightKm = rect.height * PathfinderExperience.kmPerDegreeLat

        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.blender(.medium, size: titleSize))
                .foregroundStyle(.white)
            Text(String(format: "%.1f × %.1f KM", widthKm, heightKm))
                .font(.blender(.medium, size: detailSize))
                .foregroundStyle(.white)
            Text(String(format: "%.1f KM²", widthKm * heightKm))
                .font(.blender(.medium, size: detailSize))
                .foregroundStyle(.white)
        }
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.black)
    }

    private func poiCallout(name: String, at site: CGPoint, viewportSize: CGSize) -> some View {
        let bubbleHeight: CGFloat = 26

        let bubbleOrigin = CGPoint(
            x: site.x + 20,
            y: site.y - (bubbleHeight + 12)
        )
        let elbowPoint = CGPoint(
            x: site.x + 10,
            y: site.y - 8
        )

        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: site)
                path.addLine(to: elbowPoint)
                path.addLine(to: CGPoint(x: bubbleOrigin.x, y: bubbleOrigin.y + bubbleHeight / 2))
            }
            .stroke(.white.opacity(0.82), lineWidth: 1)

            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
                .position(site)

            Text(name)
                .font(.blender(.medium, size: 11))
                .foregroundStyle(.white)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.black)
                .position(x: bubbleOrigin.x + 40, y: bubbleOrigin.y + bubbleHeight / 2)
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
    }

    private func altitudeHeightKm(liveRect: GeoRect) -> Double {
        liveRect.height * PathfinderExperience.kmPerDegreeLat
    }

    @ViewBuilder
    private func viewportOverlays(viewportSize: CGSize, focusCoordinate: MarsCoordinate, visibleWidthKm: Double, level1Opacity: Double, level2Opacity: Double, level3Opacity: Double = 0) -> some View {
        let visibleHeightKm = visibleWidthKm * Double(viewportSize.height / viewportSize.width)
        let areaKm2 = visibleWidthKm * visibleHeightKm

        VStack {
            HStack(alignment: .top) {
                Spacer()

                viewportSizePanel(widthKm: visibleWidthKm, heightKm: visibleHeightKm, areaKm2: areaKm2)
                    .padding(.top, isFullScreen ? 48 : 0)
                    .animation(.easeInOut(duration: 0.3), value: isFullScreen)
            }

            Spacer()

            HStack(alignment: .bottom) {
                Spacer()

                if model.isEnhancing {
                    Text("Preparing terrain... \(model.readyLevel1TileCount)/\(model.totalLevel1TileCount)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.black.opacity(0.5))
                                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                        )
                        .transition(.opacity)
                } else if model.tier3Loaded && !model.tier3Ready {
                    Text("Loading HiRISE detail...")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.black.opacity(0.5))
                                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                        )
                        .transition(.opacity)
                } else if model.tier2Loaded && !model.tier2Ready {
                    Text("Loading HiRISE terrain...")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.black.opacity(0.5))
                                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                        )
                        .transition(.opacity)
                }
            }
        }
        .padding(8)
        .allowsHitTesting(false)
    }

    private func viewportSizePanel(widthKm: Double, heightKm: Double, areaKm2: Double) -> some View {
        let unit: String
        let w: Double
        let h: Double
        let a: Double
        let areaUnit: String

        if useImperialUnits {
            unit = "mi"
            areaUnit = "mi²"
            w = widthKm * 0.621371
            h = heightKm * 0.621371
            a = areaKm2 * 0.386102
        } else {
            unit = "km"
            areaUnit = "km²"
            w = widthKm
            h = heightKm
            a = areaKm2
        }

        return VStack(alignment: .trailing, spacing: 4) {
            Text("\(formatValueWithCommas(w)) × \(formatValueWithCommas(h)) \(unit)")
                .font(.blender(.medium, size: 13))
                .foregroundStyle(.white)
                .monospacedDigit()

            Text("\(formatValueWithCommas(a)) \(areaUnit)")
                .font(.blender(.medium, size: 13))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formatValueWithCommas(_ value: Double) -> String {
        if value >= 100 {
            let n = NumberFormatter()
            n.numberStyle = .decimal
            n.maximumFractionDigits = 0
            return n.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))"
        } else if value >= 1 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }

    private func level1TileLayer(_ tile: Level1TileRenderState, viewportSize: CGSize, opacity: Double) -> some View {
        let frame = baseFrame(for: tile.descriptor.geoRect, viewportSize: viewportSize)

        return Group {
            if let image = model.displayImageForL1(tile.id) {
                imageLayer(image, frame: frame, interpolation: .high)
                    .opacity(opacity)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.5), value: tile.id)
    }

    private func imageLayer(_ image: CGImage, frame: CGRect, interpolation: Image.Interpolation) -> some View {
        Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            .resizable()
            .interpolation(interpolation)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    private func coordinatesChip(for coordinate: MarsCoordinate) -> some View {
        Text("\(formatLatitude(coordinate.lat))  •  \(formatLongitude(coordinate.lon))")
            .font(.inter(weight: 500, size: 11))
            .foregroundStyle(.white.opacity(0.68))
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.black.opacity(0.5))
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func updateDrag(translation: CGSize, viewportSize: CGSize) {
        if !isDragging {
            dragStartOffset = offset
            isDragging = true
        }

        offset = clampedOffset(
            CGSize(
                width: dragStartOffset.width + translation.width,
                height: dragStartOffset.height + translation.height
            ),
            viewportSize: viewportSize,
            scale: scale
        )
    }

    private func finishDrag(translation: CGSize, velocity: CGSize, viewportSize: CGSize) {
        let currentOffset = clampedOffset(
            CGSize(
                width: dragStartOffset.width + translation.width,
                height: dragStartOffset.height + translation.height
            ),
            viewportSize: viewportSize,
            scale: scale
        )

        offset = currentOffset
        isDragging = false
        scheduleSettle()
    }

    private func zoom(to proposedScale: CGFloat, anchor: CGPoint, viewportSize: CGSize, animated: Bool = false) {
        let effectiveMinScale = PathfinderExperience.minZoomScale(for: viewportSize)
        let effectiveMaxScale = PathfinderExperience.maxZoomScale

        let clampedScale = min(max(proposedScale, effectiveMinScale), effectiveMaxScale)
        let anchorPoint = baseCanvasPoint(for: anchor, viewportSize: viewportSize)

        let newOffset = CGSize(
            width: anchor.x - viewportSize.width / 2 - (anchorPoint.x - viewportSize.width / 2) * clampedScale,
            height: anchor.y - viewportSize.height / 2 - (anchorPoint.y - viewportSize.height / 2) * clampedScale
        )

        let clampedOffset = clampedOffset(newOffset, viewportSize: viewportSize, scale: clampedScale)

        if animated {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                scale = clampedScale
                offset = clampedOffset
            }
        } else {
            scale = clampedScale
            offset = clampedOffset
        }
        scheduleSettle()
    }

    private func pan(by delta: CGSize, viewportSize: CGSize) {
        offset = clampedOffset(
            CGSize(width: offset.width + delta.width, height: offset.height + delta.height),
            viewportSize: viewportSize,
            scale: scale
        )
        scheduleSettle()
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            settledScale = scale
            settledOffset = offset
        }
    }

    private func nearestMarkerIndex(to point: CGPoint, viewportSize: CGSize, threshold: CGFloat = 20) -> Int? {
        var bestIdx: Int?
        var bestDist: CGFloat = threshold
        for (i, coord) in placedMarkers.enumerated() {
            let pos = screenPosition(for: coord, viewportSize: viewportSize)
            let dx = pos.x - point.x, dy = pos.y - point.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < bestDist { bestDist = dist; bestIdx = i }
        }
        return bestIdx
    }

    private func baseCanvasPoint(for screenPoint: CGPoint, viewportSize: CGSize) -> CGPoint {
        CGPoint(
            x: (screenPoint.x - viewportSize.width / 2 - offset.width) / scale + viewportSize.width / 2,
            y: (screenPoint.y - viewportSize.height / 2 - offset.height) / scale + viewportSize.height / 2
        )
    }

    private func visibleGeoRect(forScale s: CGFloat, offset o: CGSize, viewportSize: CGSize) -> GeoRect {
        let baseDpp = PathfinderExperience.baseDegreesPerPoint(for: viewportSize)
        let dpp = baseDpp / Double(s)
        let wc = PathfinderExperience.worldRect.center

        let centerLon = wc.lon - Double(o.width) * baseDpp / Double(s)
        let centerLat = wc.lat + Double(o.height) * baseDpp / Double(s)

        let visW = Double(viewportSize.width) * dpp
        let visH = Double(viewportSize.height) * dpp

        return GeoRect(
            lonMin: centerLon - visW / 2,
            lonMax: centerLon + visW / 2,
            latMin: centerLat - visH / 2,
            latMax: centerLat + visH / 2
        )
    }

    private func coordinate(at point: CGPoint, viewportSize: CGSize) -> MarsCoordinate {
        let canvasPoint = baseCanvasPoint(for: point, viewportSize: viewportSize)
        let ppp = 1.0 / PathfinderExperience.baseDegreesPerPoint(for: viewportSize)
        let wc = PathfinderExperience.worldRect.center

        return MarsCoordinate(
            lat: wc.lat - Double(canvasPoint.y - viewportSize.height / 2) / ppp,
            lon: wc.lon + Double(canvasPoint.x - viewportSize.width / 2) / ppp
        )
    }

    private func screenPosition(for coordinate: MarsCoordinate, viewportSize: CGSize) -> CGPoint {
        let ppp = 1.0 / PathfinderExperience.baseDegreesPerPoint(for: viewportSize)
        let wc = PathfinderExperience.worldRect.center

        let baseX = viewportSize.width / 2 + CGFloat((coordinate.lon - wc.lon) * ppp)
        let baseY = viewportSize.height / 2 - CGFloat((coordinate.lat - wc.lat) * ppp)

        return CGPoint(
            x: viewportSize.width / 2 + (baseX - viewportSize.width / 2) * scale + offset.width,
            y: viewportSize.height / 2 + (baseY - viewportSize.height / 2) * scale + offset.height
        )
    }

    private func basePosition(for coordinate: MarsCoordinate, viewportSize: CGSize) -> CGPoint {
        let ppp = 1.0 / PathfinderExperience.baseDegreesPerPoint(for: viewportSize)
        let wc = PathfinderExperience.worldRect.center
        return CGPoint(
            x: viewportSize.width / 2 + CGFloat((coordinate.lon - wc.lon) * ppp),
            y: viewportSize.height / 2 - CGFloat((coordinate.lat - wc.lat) * ppp)
        )
    }

    private func baseFrame(for rect: GeoRect, viewportSize: CGSize) -> CGRect {
        let ppp = 1.0 / PathfinderExperience.baseDegreesPerPoint(for: viewportSize)
        let wc = PathfinderExperience.worldRect.center

        return CGRect(
            x: Double(viewportSize.width) / 2 + (rect.lonMin - wc.lon) * ppp,
            y: Double(viewportSize.height) / 2 - (rect.latMax - wc.lat) * ppp,
            width: rect.width * ppp,
            height: rect.height * ppp
        )
    }


    private func clampedOffset(_ proposedOffset: CGSize, viewportSize: CGSize, scale: CGFloat) -> CGSize {
        let baseDpp = PathfinderExperience.baseDegreesPerPoint(for: viewportSize)
        let dpp = baseDpp / Double(scale)
        let halfVisW = Double(viewportSize.width) * dpp / 2
        let halfVisH = Double(viewportSize.height) * dpp / 2
        let wc = PathfinderExperience.worldRect.center

        // Progressive viewport clamping: tighten the clamp rect as zoom increases
        let viewportWidthKm = Double(viewportSize.width) * dpp * PathfinderExperience.kmPerDegreeLon(at: PathfinderExperience.pathfinder.lat)
        let cr = effectiveClampRect(for: viewportWidthKm)

        let proposedLon = wc.lon - Double(proposedOffset.width) * baseDpp / Double(scale)
        let proposedLat = wc.lat + Double(proposedOffset.height) * baseDpp / Double(scale)

        let lonLo = cr.lonMin + halfVisW
        let lonHi = cr.lonMax - halfVisW
        let clampedLon = lonLo < lonHi ? min(max(proposedLon, lonLo), lonHi) : cr.center.lon

        let latLo = cr.latMin + halfVisH
        let latHi = cr.latMax - halfVisH
        let clampedLat = latLo < latHi ? min(max(proposedLat, latLo), latHi) : cr.center.lat

        let pps = Double(scale) / baseDpp
        return CGSize(
            width: -(clampedLon - wc.lon) * pps,
            height: (clampedLat - wc.lat) * pps
        )
    }

    private func effectiveClampRect(for viewportWidthKm: Double) -> GeoRect {
        // Free pan at all zoom levels — the tier 2 mosaic edges naturally
        // isolate the area of interest, so pan locking is not needed.
        return PathfinderExperience.tileCoverageRect
    }

    private func telemetryResolution(widthKm: Double, viewportWidth: CGFloat) -> String {
        let mPerPx = (widthKm * 1000) / Double(viewportWidth)
        if useImperialUnits {
            let ftPerPx = mPerPx * 3.28084
            if ftPerPx >= 5280 {
                return String(format: "~ %.0f mi/px", ftPerPx / 5280)
            } else if ftPerPx >= 1 {
                return String(format: "~ %.0f ft/px", ftPerPx)
            } else {
                return String(format: "~ %.1f in/px", ftPerPx * 12)
            }
        }
        if mPerPx >= 1000 {
            return String(format: "~ %.0f km/px", mPerPx / 1000)
        } else if mPerPx >= 1 {
            return String(format: "~ %.0f m/px", mPerPx)
        } else {
            return String(format: "~ %.0f cm/px", mPerPx * 100)
        }
    }

    private func telemetryFieldOfView(viewportSize: CGSize) -> String {
        let rect = visibleGeoRect(forScale: scale, offset: offset, viewportSize: viewportSize)
        let marsRadiusKm = PathfinderExperience.marsRadiusKm
        let marsSurfaceArea = 4.0 * .pi * marsRadiusKm * marsRadiusKm
        let widthKm = rect.width * PathfinderExperience.kmPerDegreeLon(at: rect.center.lat)
        let heightKm = rect.height * PathfinderExperience.kmPerDegreeLat
        let viewArea = widthKm * heightKm
        let pct = viewArea / marsSurfaceArea * 100
        if pct >= 1 {
            return String(format: "%.0f%% of Mars", pct)
        } else if pct >= 0.1 {
            return String(format: "%.1f%% of Mars", pct)
        } else if pct >= 0.01 {
            return String(format: "%.2f%% of Mars", pct)
        } else {
            let exp = Int(floor(log10(pct)))
            let mantissa = pct / pow(10, Double(exp))
            let superscripts = String(String(exp).map { c in
                switch c {
                case "-": return "\u{207B}"
                case "0": return "\u{2070}"
                case "1": return "\u{00B9}"
                case "2": return "\u{00B2}"
                case "3": return "\u{00B3}"
                case "4": return "\u{2074}"
                case "5": return "\u{2075}"
                case "6": return "\u{2076}"
                case "7": return "\u{2077}"
                case "8": return "\u{2078}"
                case "9": return "\u{2079}"
                default: return c
                }
            })
            return String(format: "%.1f", mantissa) + " × 10\(superscripts)% of Mars"
        }
    }

    private func lerpRect(from a: GeoRect, to b: GeoRect, t: Double) -> GeoRect {
        GeoRect(
            lonMin: a.lonMin + (b.lonMin - a.lonMin) * t,
            lonMax: a.lonMax + (b.lonMax - a.lonMax) * t,
            latMin: a.latMin + (b.latMin - a.latMin) * t,
            latMax: a.latMax + (b.latMax - a.latMax) * t
        )
    }

    private func ctxL1Opacity(for currentScale: CGFloat) -> Double {
        guard !ctxAlwaysMode else { return 1.0 }
        let normalizedZoom = min(max((Double(currentScale) - 1.0) / (Double(PathfinderExperience.maxZoomScale) - 1.0), 0), 1)
        let inv = 1.0 - normalizedZoom
        return 1.0 - inv * inv * inv
    }

    private func tierOpacity(for visibleWidthKm: Double, start: Double, end: Double) -> Double {
        guard start > end else { return 0 }
        let progress = (start - visibleWidthKm) / (start - end)
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func tileRequestKey(for rect: GeoRect, scale: CGFloat, visibleTileBudget: Int, level3Budget: Int = 0) -> String {
        [
            "\(Int(scale * 10))",
            "\(Int(rect.lonMin * 100))",
            "\(Int(rect.lonMax * 100))",
            "\(Int(rect.latMin * 100))",
            "\(Int(rect.latMax * 100))",
            "\(visibleTileBudget)",
            "\(level3Budget)",
        ].joined(separator: "_")
    }

    private func formatDistance(_ kilometers: Double) -> String {
        if useImperialUnits {
            let miles = kilometers * 0.621371
            if miles >= 100 {
                return "\(Int(miles.rounded())) mi"
            }
            if miles >= 1 {
                return String(format: "%.1f mi", miles)
            }
            let feet = kilometers * 3280.84
            return "\(Int(feet.rounded())) ft"
        } else {
            if kilometers >= 100 {
                return "\(Int(kilometers.rounded())) km"
            }
            if kilometers >= 1 {
                return String(format: "%.1f km", kilometers)
            }
            return "\(Int((kilometers * 1000).rounded())) m"
        }
    }

    private func formatLatitude(_ latitude: Double) -> String {
        String(format: "%.2f°%@", abs(latitude), latitude >= 0 ? "N" : "S")
    }

    private func formatLongitude(_ longitude: Double) -> String {
        String(format: "%.2f°E", longitude)
    }
}

enum VikingMosaicProvider {
    private static let lock = NSLock()
    private static var cachedImage: CGImage?

    static func releaseCache() {
        lock.lock()
        defer { lock.unlock() }
        cachedImage = nil
    }

    // Viking 23K mosaic registration correction (measured via cross-correlation with CTX tiles)
    // The mosaic pixel grid is offset from the standard 0°E/90°N origin
    private static let lonCorrection = -1.906  // shift crop west to align with CTX
    private static let latCorrection = 0.812   // shift crop north to align with CTX

    static func crop(rect: GeoRect, targetWidth: Int) -> CGImage? {
        guard let fullImage = fullImage() else { return nil }

        let corrected = GeoRect(
            lonMin: rect.lonMin + lonCorrection,
            lonMax: rect.lonMax + lonCorrection,
            latMin: rect.latMin + latCorrection,
            latMax: rect.latMax + latCorrection
        )
        var cropRect = corrected.pixelRect(imageWidth: fullImage.width, imageHeight: fullImage.height).integral
        cropRect.origin.x = max(cropRect.origin.x, 0)
        cropRect.origin.y = max(cropRect.origin.y, 0)
        cropRect.size.width = min(cropRect.width, CGFloat(fullImage.width) - cropRect.origin.x)
        cropRect.size.height = min(cropRect.height, CGFloat(fullImage.height) - cropRect.origin.y)

        guard let cropped = fullImage.cropping(to: cropRect) else { return nil }

        let aspect = rect.height / rect.width
        let targetHeight = max(Int((Double(targetWidth) * aspect).rounded()), 1)

        return TileManager.resizeImage(
            cropped,
            to: CGSize(width: targetWidth, height: targetHeight),
            grayscale: false,
            interpolation: .high
        )
    }

    private static func fullImage() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }

        if let cachedImage { return cachedImage }

        guard let nsImage = NSImage(named: "mars_diffuse"),
              let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        cachedImage = image
        return image
    }
}

private enum TerrainColorizer {
    private static let whiteX = 0.95047
    private static let whiteY = 1.0
    private static let whiteZ = 1.08883

    static func colorize(luminanceImage: CGImage, usingChromaFrom colorImage: CGImage) -> CGImage? {
        let targetWidth = luminanceImage.width
        let targetHeight = luminanceImage.height

        guard let grayBytes = TileManager.grayBytes(from: luminanceImage),
              let resizedColor = TileManager.resizeImage(
                colorImage,
                to: CGSize(width: targetWidth, height: targetHeight),
                grayscale: false,
                interpolation: .high
              ),
              let colorBytes = rgbaBytes(from: resizedColor)
        else { return nil }

        var output = [UInt8](repeating: 255, count: targetWidth * targetHeight * 4)

        for pixelIndex in 0..<(targetWidth * targetHeight) {
            let gray = Double(grayBytes[pixelIndex]) / 255.0
            let colorOffset = pixelIndex * 4

            let red = Double(colorBytes[colorOffset]) / 255.0
            let green = Double(colorBytes[colorOffset + 1]) / 255.0
            let blue = Double(colorBytes[colorOffset + 2]) / 255.0

            var lab = rgbToLab(r: red, g: green, b: blue)
            lab.l = lightness(from: gray)

            let rgb = labToRGB(l: lab.l, a: lab.a, b: lab.b)
            output[colorOffset] = UInt8(max(0, min(1, rgb.r)) * 255)
            output[colorOffset + 1] = UInt8(max(0, min(1, rgb.g)) * 255)
            output[colorOffset + 2] = UInt8(max(0, min(1, rgb.b)) * 255)
            output[colorOffset + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: targetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    fileprivate static func rgbaBytes(from image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private static func lightness(from grayscale: Double) -> Double {
        let linear = grayscale <= 0.04045
            ? grayscale / 12.92
            : pow((grayscale + 0.055) / 1.055, 2.4)

        let normalizedY = linear / whiteY
        let f = labFunction(normalizedY)
        return max(0, min(100, 116 * f - 16))
    }

    private static func rgbToLab(r: Double, g: Double, b: Double) -> (l: Double, a: Double, b: Double) {
        let linearR = r <= 0.04045 ? r / 12.92 : pow((r + 0.055) / 1.055, 2.4)
        let linearG = g <= 0.04045 ? g / 12.92 : pow((g + 0.055) / 1.055, 2.4)
        let linearB = b <= 0.04045 ? b / 12.92 : pow((b + 0.055) / 1.055, 2.4)

        let x = (0.4124564 * linearR + 0.3575761 * linearG + 0.1804375 * linearB) / whiteX
        let y = (0.2126729 * linearR + 0.7151522 * linearG + 0.0721750 * linearB) / whiteY
        let z = (0.0193339 * linearR + 0.1191920 * linearG + 0.9503041 * linearB) / whiteZ

        let fx = labFunction(x)
        let fy = labFunction(y)
        let fz = labFunction(z)

        return (
            l: 116 * fy - 16,
            a: 500 * (fx - fy),
            b: 200 * (fy - fz)
        )
    }

    private static func labToRGB(l: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let fy = (l + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200

        let x = whiteX * inverseLabFunction(fx)
        let y = whiteY * inverseLabFunction(fy)
        let z = whiteZ * inverseLabFunction(fz)

        let linearR = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let linearG = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let linearB = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z

        return (
            r: gammaEncode(linearR),
            g: gammaEncode(linearG),
            b: gammaEncode(linearB)
        )
    }

    private static func labFunction(_ value: Double) -> Double {
        value > 216.0 / 24_389.0
            ? pow(value, 1.0 / 3.0)
            : (24_389.0 / 27.0 * value + 16) / 116
    }

    private static func inverseLabFunction(_ value: Double) -> Double {
        let cube = value * value * value
        return cube > 216.0 / 24_389.0
            ? cube
            : (116 * value - 16) / (24_389.0 / 27.0)
    }

    private static func gammaEncode(_ value: Double) -> Double {
        let clamped = max(0, value)
        return clamped <= 0.0031308
            ? 12.92 * clamped
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}

private final class FPSDisplayLinkTarget {
    var onFPS: ((Int) -> Void)?
    private var timer: DispatchSourceTimer?
    private var frameCount: Int = 0
    private var lastSample: CFAbsoluteTime = 0

    func start() {
        lastSample = CFAbsoluteTimeGetCurrent()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(8))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.frameCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastSample >= 1.0 {
                self.onFPS?(Int(Double(self.frameCount) / (now - self.lastSample)))
                self.frameCount = 0
                self.lastSample = now
            }
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

private struct TierCutoutMask: ViewModifier {
    let isActive: Bool
    let cutoutFrame: CGRect
    let cutoutOpacity: Double

    func body(content: Content) -> some View {
        if isActive {
            content.mask {
                ZStack {
                    Rectangle()
                        .fill(Color.white)
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: cutoutFrame.width, height: cutoutFrame.height)
                        .position(x: cutoutFrame.midX, y: cutoutFrame.midY)
                        .blendMode(.destinationOut)
                        .opacity(cutoutOpacity)
                }
                .compositingGroup()
            }
        } else {
            content
        }
    }
}

private struct ViewportInteractionLayer: NSViewRepresentable {
    @Binding var cursorPoint: CGPoint?
    let onScroll: (NSEvent) -> Void
    let onMagnify: (CGFloat, CGPoint?) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize, CGSize) -> Void
    var onClick: ((CGPoint) -> Void)?
    var onOptionDrag: ((CGPoint) -> Void)?
    var onOptionDragEnd: (() -> Void)?

    func makeNSView(context: Context) -> ViewportInteractionNSView {
        let view = ViewportInteractionNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ViewportInteractionNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: ViewportInteractionNSView) {
        view.onMove = { point in
            cursorPoint = point
        }
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onClick = onClick
        view.onOptionDrag = onOptionDrag
        view.onOptionDragEnd = onOptionDragEnd
    }
}

private final class ViewportInteractionNSView: NSView {
    var onMove: ((CGPoint?) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onMagnify: ((CGFloat, CGPoint?) -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: ((CGSize, CGSize) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onOptionDrag: ((CGPoint) -> Void)?
    var onOptionDragEnd: (() -> Void)?
    private var isOptionDrag = false

    private var trackingArea: NSTrackingArea?
    private var dragStartPoint: CGPoint?
    private var lastDragPoint: CGPoint?
    private var lastDragTimestamp: TimeInterval?
    private var dragVelocity: CGSize = .zero

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        onMove?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onMove?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onMove?(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        onMove?(convert(event.locationInWindow, from: nil))
        onScroll?(event)
    }

    override func magnify(with event: NSEvent) {
        onMove?(convert(event.locationInWindow, from: nil))
        onMagnify?(CGFloat(event.magnification), convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isOptionDrag = event.modifierFlags.contains(.option)
        dragStartPoint = point
        lastDragPoint = point
        lastDragTimestamp = event.timestamp
        dragVelocity = .zero
        onMove?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint else { return }

        let point = convert(event.locationInWindow, from: nil)
        let translation = CGSize(
            width: point.x - dragStartPoint.x,
            height: point.y - dragStartPoint.y
        )

        // Ignore tiny movements (prevents flash on click)
        let distance = sqrt(translation.width * translation.width + translation.height * translation.height)
        guard distance > 2 else { return }

        if isOptionDrag {
            onOptionDrag?(point)
            return
        }

        if let lastDragPoint, let lastDragTimestamp {
            let deltaTime = max(event.timestamp - lastDragTimestamp, 1.0 / 240.0)
            dragVelocity = CGSize(
                width: (point.x - lastDragPoint.x) / deltaTime,
                height: (point.y - lastDragPoint.y) / deltaTime
            )
        }

        self.lastDragPoint = point
        self.lastDragTimestamp = event.timestamp
        onMove?(point)
        onDragChanged?(translation)
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStartPoint else { return }

        let point = convert(event.locationInWindow, from: nil)
        let translation = CGSize(
            width: point.x - dragStartPoint.x,
            height: point.y - dragStartPoint.y
        )

        let distance = sqrt(translation.width * translation.width + translation.height * translation.height)
        if isOptionDrag {
            if distance > 2 {
                onOptionDragEnd?()
            } else {
                onClick?(point)
            }
        } else if distance > 2 {
            onMove?(point)
            onDragEnded?(translation, dragVelocity)
        }
        isOptionDrag = false

        self.dragStartPoint = nil
        lastDragPoint = nil
        lastDragTimestamp = nil
        dragVelocity = .zero
    }
}
