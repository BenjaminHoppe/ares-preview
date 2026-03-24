import CoreGraphics
import Foundation
import ImageIO

struct MarsCoordinate: Hashable {
    let lat: Double
    let lon: Double
}

struct GeoRect: Hashable {
    let lonMin: Double
    let lonMax: Double
    let latMin: Double
    let latMax: Double

    var width: Double { lonMax - lonMin }
    var height: Double { latMax - latMin }
    var center: MarsCoordinate {
        MarsCoordinate(lat: (latMin + latMax) / 2, lon: (lonMin + lonMax) / 2)
    }

    func intersects(_ other: GeoRect) -> Bool {
        !(other.lonMax <= lonMin || other.lonMin >= lonMax || other.latMax <= latMin || other.latMin >= latMax)
    }

    func intersection(with other: GeoRect) -> GeoRect? {
        guard intersects(other) else { return nil }
        return GeoRect(
            lonMin: max(lonMin, other.lonMin),
            lonMax: min(lonMax, other.lonMax),
            latMin: max(latMin, other.latMin),
            latMax: min(latMax, other.latMax)
        )
    }

    func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect {
        let x = lonMin / 360.0 * Double(imageWidth)
        let y = (90.0 - latMax) / 180.0 * Double(imageHeight)
        let width = self.width / 360.0 * Double(imageWidth)
        let height = self.height / 180.0 * Double(imageHeight)

        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct CTXRawTileDescriptor: Hashable, Identifiable {
    let name: String
    let lonSW: Double
    let latSW: Double

    var id: String { name }
    var geoRect: GeoRect {
        GeoRect(lonMin: lonSW, lonMax: lonSW + CTXTileLoader.degreesPerRaw, latMin: latSW, latMax: latSW + CTXTileLoader.degreesPerRaw)
    }

    var level1URL: URL {
        CTXTileLoader.level1Directory.appendingPathComponent("\(name).png")
    }

    var level2DirectoryURL: URL {
        CTXTileLoader.level2Directory.appendingPathComponent(name)
    }
}

struct CTXLevel2TileDescriptor: Hashable, Identifiable {
    let rawTile: CTXRawTileDescriptor
    let row: Int
    let column: Int

    var id: String {
        "\(rawTile.name)_\(row)_\(column)"
    }

    var geoRect: GeoRect {
        let tileSpan = CTXTileLoader.degreesPerLevel2
        let lonMin = rawTile.lonSW + Double(column) * tileSpan
        let lonMax = lonMin + tileSpan
        let latMax = rawTile.latSW + CTXTileLoader.degreesPerRaw - Double(row) * tileSpan
        let latMin = latMax - tileSpan

        return GeoRect(lonMin: lonMin, lonMax: lonMax, latMin: latMin, latMax: latMax)
    }

    var url: URL {
        rawTile.level2DirectoryURL.appendingPathComponent(String(format: "%04d_%04d.jpg", row, column))
    }

    var center: MarsCoordinate {
        geoRect.center
    }
}

enum CTXTileLoader {
    static let level1Directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ares-data/ship-packs/ctx/tiles/level1")

    static let level2Directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ares-data/ship-packs/ctx/tiles/level2_colour")

    static let level2TileSize = 512
    static let tilesPerRaw = 92
    static let degreesPerRaw = 4.0
    static let degreesPerLevel2 = degreesPerRaw / Double(tilesPerRaw)
    static let epsilon = 0.000_001

    static let pathfinder = MarsCoordinate(lat: 19.10, lon: 326.75)

    static func rawTile(containing coordinate: MarsCoordinate) -> CTXRawTileDescriptor {
        let lonSW = floor(coordinate.lon / degreesPerRaw) * degreesPerRaw
        let latSW = floor(coordinate.lat / degreesPerRaw) * degreesPerRaw
        return rawTile(lonSW: lonSW, latSW: latSW)
    }

    static func rawTiles(intersecting rect: GeoRect, requiringLevel2Data: Bool = false) -> [CTXRawTileDescriptor] {
        let lonStart = floor(rect.lonMin / degreesPerRaw) * degreesPerRaw
        let lonEnd = floor((rect.lonMax - epsilon) / degreesPerRaw) * degreesPerRaw
        let latStart = floor(rect.latMin / degreesPerRaw) * degreesPerRaw
        let latEnd = floor((rect.latMax - epsilon) / degreesPerRaw) * degreesPerRaw

        var results: [CTXRawTileDescriptor] = []
        var lat = latStart
        while lat <= latEnd {
            var lon = lonStart
            while lon <= lonEnd {
                let tile = rawTile(lonSW: lon, latSW: lat)
                let hasRequiredData = requiringLevel2Data
                    ? FileManager.default.fileExists(atPath: tile.level2DirectoryURL.path)
                    : FileManager.default.fileExists(atPath: tile.level1URL.path)

                if hasRequiredData {
                    results.append(tile)
                }
                lon += degreesPerRaw
            }
            lat += degreesPerRaw
        }

        return results
    }

    static func level2Tiles(in rect: GeoRect) -> [CTXLevel2TileDescriptor] {
        rawTiles(intersecting: rect, requiringLevel2Data: true).flatMap { rawTile in
            guard let intersection = rect.intersection(with: rawTile.geoRect) else {
                return [CTXLevel2TileDescriptor]()
            }

            let northEdge = rawTile.latSW + degreesPerRaw

            let columnStart = clamp(Int(floor((intersection.lonMin - rawTile.lonSW) / degreesPerLevel2)), min: 0, max: tilesPerRaw - 1)
            let columnEnd = clamp(Int(floor((intersection.lonMax - epsilon - rawTile.lonSW) / degreesPerLevel2)), min: 0, max: tilesPerRaw - 1)

            let rowStart = clamp(Int(floor((northEdge - intersection.latMax) / degreesPerLevel2)), min: 0, max: tilesPerRaw - 1)
            let rowEnd = clamp(Int(floor((northEdge - (intersection.latMin + epsilon)) / degreesPerLevel2)), min: 0, max: tilesPerRaw - 1)

            guard rowStart <= rowEnd, columnStart <= columnEnd else {
                return [CTXLevel2TileDescriptor]()
            }

            var results: [CTXLevel2TileDescriptor] = []
            for row in rowStart...rowEnd {
                for column in columnStart...columnEnd {
                    let descriptor = CTXLevel2TileDescriptor(rawTile: rawTile, row: row, column: column)
                    if FileManager.default.fileExists(atPath: descriptor.url.path) {
                        results.append(descriptor)
                    }
                }
            }
            return results
        }
    }

    static func loadLevel1Image(for rawTile: CTXRawTileDescriptor, maxDimension: Int? = nil) -> CGImage? {
        loadCGImage(at: rawTile.level1URL, maxDimension: maxDimension)
    }

    static func loadLevel2Image(for descriptor: CTXLevel2TileDescriptor) -> CGImage? {
        loadCGImage(at: descriptor.url, maxDimension: nil)
    }

    private static func rawTile(lonSW: Double, latSW: Double) -> CTXRawTileDescriptor {
        let name = rawTileName(lonSW: lonSW, latSW: latSW)
        return CTXRawTileDescriptor(name: name, lonSW: lonSW, latSW: latSW)
    }

    private static func rawTileName(lonSW: Double, latSW: Double) -> String {
        var eastLon = Int(lonSW)
        if eastLon > 180 {
            eastLon -= 360
        }

        let eastString = eastLon < 0
            ? String(format: "E-%03d", abs(eastLon))
            : String(format: "E%03d", eastLon)
        let northString = latSW < 0
            ? String(format: "N-%02d", abs(Int(latSW)))
            : String(format: "N%02d", Int(latSW))

        return "MurrayLab_CTX_V01_\(eastString)_\(northString)"
    }

    private static func loadCGImage(at url: URL, maxDimension: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        if let maxDimension {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.min(Swift.max(value, minValue), maxValue)
    }
}
