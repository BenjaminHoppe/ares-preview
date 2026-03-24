import CoreGraphics
import Foundation
import ImageIO

struct HiRISETileDescriptor: Hashable, Identifiable {
    let row: Int
    let column: Int

    var id: String { String(format: "%04d_%04d", row, column) }

    var geoRect: GeoRect {
        let lonMin = HiRISETileLoader.lonMin + Double(column) * HiRISETileLoader.degreesPerTileLon
        let latMax = HiRISETileLoader.latMax - Double(row) * HiRISETileLoader.degreesPerTileLat
        return GeoRect(
            lonMin: lonMin,
            lonMax: lonMin + HiRISETileLoader.degreesPerTileLon,
            latMin: latMax - HiRISETileLoader.degreesPerTileLat,
            latMax: latMax
        )
    }

    var url: URL {
        HiRISETileLoader.tileDirectory.appendingPathComponent(String(format: "%04d_%04d.jpg", row, column))
    }

    var center: MarsCoordinate { geoRect.center }
}

enum HiRISETileLoader {
    // From tile_metadata.json (PSP_001890_1995)
    static let gridRows = 115
    static let gridCols = 58
    static let latMin = 18.960900849045
    static let latMax = 19.211031724031
    static let lonMin = 326.69734790153
    static let lonMax = 326.82895029345
    static let tileSize = 512
    static let mapScaleMetersPerPixel = 0.25

    static let degreesPerTileLon = (lonMax - lonMin) / Double(gridCols)
    static let degreesPerTileLat = (latMax - latMin) / Double(gridRows)

    static let coverageRect = GeoRect(lonMin: lonMin, lonMax: lonMax, latMin: latMin, latMax: latMax)

    static let tileDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ares-data/hirise/pathfinder/tiles")

    private static let epsilon = 0.000_001

    static func tiles(in rect: GeoRect) -> [HiRISETileDescriptor] {
        guard let intersection = rect.intersection(with: coverageRect) else {
            return []
        }

        let colStart = clamp(Int(floor((intersection.lonMin - lonMin) / degreesPerTileLon)), min: 0, max: gridCols - 1)
        let colEnd = clamp(Int(floor((intersection.lonMax - epsilon - lonMin) / degreesPerTileLon)), min: 0, max: gridCols - 1)
        let rowStart = clamp(Int(floor((latMax - intersection.latMax) / degreesPerTileLat)), min: 0, max: gridRows - 1)
        let rowEnd = clamp(Int(floor((latMax - (intersection.latMin + epsilon)) / degreesPerTileLat)), min: 0, max: gridRows - 1)

        guard rowStart <= rowEnd, colStart <= colEnd else { return [] }

        var results: [HiRISETileDescriptor] = []
        for row in rowStart...rowEnd {
            for col in colStart...colEnd {
                let descriptor = HiRISETileDescriptor(row: row, column: col)
                if FileManager.default.fileExists(atPath: descriptor.url.path) {
                    results.append(descriptor)
                }
            }
        }
        return results
    }

    static func loadImage(for descriptor: HiRISETileDescriptor) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(descriptor.url as CFURL, nil) else { return nil }
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
