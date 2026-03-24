import Foundation

enum AresEnvironment: String, CaseIterable {
    case sampleSize = "Sample Size"

    var icon: String {
        switch self {
        case .sampleSize: return "ruler"
        }
    }
}

enum TerrainSource: String, CaseIterable {
    case prebaked
    case local

    var title: String {
        switch self {
        case .prebaked: return "Prebaked"
        case .local: return "Local"
        }
    }

    var onboardingLabel: String {
        switch self {
        case .prebaked: return "pre-upscaled (instant)"
        case .local: return "run locally (~ 15 mins)"
        }
    }

    var commandValue: String {
        switch self {
        case .prebaked: return "pre-upscaled"
        case .local: return "run-locally"
        }
    }

    var settingsDescription: String {
        switch self {
        case .prebaked:
            return "Prebaked terrain is already enhanced and bundled with Ares. Tier 1, 2, and 3 launch immediately with no first-run render."
        case .local:
            return "Local terrain is generated on this Mac and stored outside the app bundle. It takes about 15 minutes the first time, then Ares reuses your cached render."
        }
    }
}

enum TerrainAssetPaths {
    static let level1ExpectedTileCount = 40
    static let tier2ExpectedStripCount = 36
    static let tier3ExpectedStripCount = 36

    private static let fileManager = FileManager.default

    private static let localAppSupportRoot: URL = {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Ares Preview", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let localLevel1EnhancedDirectory: URL = {
        let dir = localAppSupportRoot.appendingPathComponent("tiles", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let localLevel1RawDirectory: URL = {
        let dir = localAppSupportRoot.appendingPathComponent("tiles_raw", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let localTier2StripDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ares-data/hirise/pathfinder/tier2_strips", isDirectory: true)

    static let localTier3StripDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ares-data/hirise/pathfinder/tier3_strips", isDirectory: true)

    private static var bundledRootDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Mosaics/PathfinderTerrain", isDirectory: true)
    }

    private static var bundledLevel1EnhancedDirectory: URL? {
        bundledRootDirectory?.appendingPathComponent("level1/enhanced", isDirectory: true)
    }

    private static var bundledLevel1RawDirectory: URL? {
        bundledRootDirectory?.appendingPathComponent("level1/raw", isDirectory: true)
    }

    private static var bundledTier2StripDirectory: URL? {
        bundledRootDirectory?.appendingPathComponent("level2", isDirectory: true)
    }

    private static var bundledTier3StripDirectory: URL? {
        bundledRootDirectory?.appendingPathComponent("level3", isDirectory: true)
    }

    static var currentSource: TerrainSource {
        TerrainSource(rawValue: UserDefaults.standard.string(forKey: "terrainSourceMode") ?? "") ?? .prebaked
    }

    static func level1EnhancedDirectory(for source: TerrainSource = currentSource) -> URL? {
        resolve(preferred: source == .local ? localLevel1EnhancedDirectory : bundledLevel1EnhancedDirectory,
                fallback: source == .local ? bundledLevel1EnhancedDirectory : localLevel1EnhancedDirectory)
    }

    static func level1RawDirectory(for source: TerrainSource = currentSource) -> URL? {
        resolve(preferred: source == .local ? localLevel1RawDirectory : bundledLevel1RawDirectory,
                fallback: source == .local ? bundledLevel1RawDirectory : localLevel1RawDirectory)
    }

    static func tier2StripDirectory(for source: TerrainSource = currentSource) -> URL? {
        resolve(preferred: source == .local ? localTier2StripDirectory : bundledTier2StripDirectory,
                fallback: source == .local ? bundledTier2StripDirectory : localTier2StripDirectory)
    }

    static func tier3StripDirectory(for source: TerrainSource = currentSource) -> URL? {
        resolve(preferred: source == .local ? localTier3StripDirectory : bundledTier3StripDirectory,
                fallback: source == .local ? bundledTier3StripDirectory : localTier3StripDirectory)
    }

    static var localRenderReady: Bool {
        imageFileCount(at: localLevel1EnhancedDirectory) >= level1ExpectedTileCount &&
        imageFileCount(at: localLevel1RawDirectory) >= level1ExpectedTileCount &&
        imageFileCount(at: localTier2StripDirectory) >= tier2ExpectedStripCount &&
        imageFileCount(at: localTier3StripDirectory) >= tier3ExpectedStripCount
    }

    static var localRenderedSizeBytes: Int64 {
        directorySize(at: localLevel1EnhancedDirectory) +
        directorySize(at: localLevel1RawDirectory) +
        directorySize(at: localTier2StripDirectory) +
        directorySize(at: localTier3StripDirectory)
    }

    static var localRenderedSizeString: String {
        guard localRenderedSizeBytes > 0 else { return "Empty" }
        return ByteCountFormatter.string(fromByteCount: localRenderedSizeBytes, countStyle: .file)
    }

    static func clearLocalRenderedData() {
        clearDirectory(localLevel1EnhancedDirectory)
        clearDirectory(localLevel1RawDirectory)
        clearDirectory(localTier2StripDirectory)
        clearDirectory(localTier3StripDirectory)
    }

    static func finderRevealDirectory(for source: TerrainSource = currentSource) -> URL {
        if source == .prebaked, let bundledRootDirectory {
            return bundledRootDirectory
        }

        if fileManager.fileExists(atPath: localTier2StripDirectory.path) {
            return localTier2StripDirectory.deletingLastPathComponent()
        }
        return localAppSupportRoot
    }

    private static func resolve(preferred: URL?, fallback: URL?) -> URL? {
        if hasImages(at: preferred) {
            return preferred
        }
        if hasImages(at: fallback) {
            return fallback
        }
        return preferred ?? fallback
    }

    private static func hasImages(at url: URL?) -> Bool {
        imageFileCount(at: url) > 0
    }

    private static func imageFileCount(at url: URL?) -> Int {
        guard let url,
              let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return 0
        }

        return contents.reduce(into: 0) { count, file in
            if ["jpg", "jpeg", "png"].contains(file.pathExtension.lowercased()) {
                count += 1
            }
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var totalBytes: Int64 = 0
        for case let file as URL in enumerator {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalBytes += Int64(size)
            }
        }

        return totalBytes
    }

    private static func clearDirectory(_ url: URL) {
        if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for file in contents {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
