import CoreGraphics
import Foundation
import ImageIO

struct HiRISETier2TileDescriptor: Hashable, Identifiable {
    let row: Int
    let column: Int

    var id: String { String(format: "t2_%04d_%04d", row, column) }

    var geoRect: GeoRect {
        let lonMin = HiRISETier2Loader.lonMin + Double(column) * HiRISETier2Loader.degreesPerTileLon
        let latMax = HiRISETier2Loader.latMax - Double(row) * HiRISETier2Loader.degreesPerTileLat
        return GeoRect(
            lonMin: lonMin,
            lonMax: lonMin + HiRISETier2Loader.degreesPerTileLon,
            latMin: latMax - HiRISETier2Loader.degreesPerTileLat,
            latMax: latMax
        )
    }

    var url: URL {
        HiRISETier2Loader.tileDirectory.appendingPathComponent(String(format: "%04d_%04d.jpg", row, column))
    }

    var center: MarsCoordinate { geoRect.center }
}

/// Loader for HiRISE tiles downsampled 4× to ~1 m/px (Tier 2 input).
/// Largest axis-aligned rectangle within the PSP_001890_1995 swath: 4.1 × 13.9 km.
enum HiRISETier2Loader {
    // From tier2_input_full/metadata.json
    static let gridRows = 27
    static let gridCols = 8
    static let latMin = 18.967426002305505
    static let latMax = 19.20233151968366
    static let lonMin = 326.7291139961314
    static let lonMax = 326.80172221236313
    static let tileSize = 512
    static let mapScaleMetersPerPixel = 1.0

    static let degreesPerTileLon = (lonMax - lonMin) / Double(gridCols)
    static let degreesPerTileLat = (latMax - latMin) / Double(gridRows)

    static let coverageRect = GeoRect(lonMin: lonMin, lonMax: lonMax, latMin: latMin, latMax: latMax)

    static let tileDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ares-data/hirise/pathfinder/tier2_input_full")

    private static let epsilon = 0.000_001

    static func tiles(in rect: GeoRect) -> [HiRISETier2TileDescriptor] {
        guard let intersection = rect.intersection(with: coverageRect) else {
            return []
        }

        let colStart = clamp(Int(floor((intersection.lonMin - lonMin) / degreesPerTileLon)), min: 0, max: gridCols - 1)
        let colEnd = clamp(Int(floor((intersection.lonMax - epsilon - lonMin) / degreesPerTileLon)), min: 0, max: gridCols - 1)
        let rowStart = clamp(Int(floor((latMax - intersection.latMax) / degreesPerTileLat)), min: 0, max: gridRows - 1)
        let rowEnd = clamp(Int(floor((latMax - (intersection.latMin + epsilon)) / degreesPerTileLat)), min: 0, max: gridRows - 1)

        guard rowStart <= rowEnd, colStart <= colEnd else { return [] }

        var results: [HiRISETier2TileDescriptor] = []
        for row in rowStart...rowEnd {
            for col in colStart...colEnd {
                let descriptor = HiRISETier2TileDescriptor(row: row, column: col)
                if FileManager.default.fileExists(atPath: descriptor.url.path) {
                    results.append(descriptor)
                }
            }
        }
        return results
    }

    static func loadImage(for descriptor: HiRISETier2TileDescriptor) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(descriptor.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary)
    }

    private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.min(Swift.max(value, minValue), maxValue)
    }
}
