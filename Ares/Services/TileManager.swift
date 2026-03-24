import CoreGraphics
import CoreML
import Foundation

enum ModelVersion: String {
    case v051_2500 = "v0.5.1 2.5K"

    var compiledURL: URL {
        if let overridePath = ProcessInfo.processInfo.environment["ARES_ML_MODEL_PATH"] {
            return URL(fileURLWithPath: overridePath)
        }
        return Bundle.main.url(forResource: "MarsTerrainSR_v051_2500", withExtension: "mlmodelc")!
    }
}

struct EnhancedTileResult {
    let image: CGImage
    let elapsedMs: Double
}


final class TileManager: @unchecked Sendable {
    static let modelInputSize = 128
    static let modelOutputSize = 512
    static let tileInputSize = 512
    static let tileOutputSize = modelOutputSize * 4
    static let inputPadding = 16
    static let paddedTileInputSize = tileInputSize + inputPadding * 2
    static let patchGridSize = 5
    static let patchStrideInput = (paddedTileInputSize - modelInputSize) / (patchGridSize - 1)
    static let upscaleFactor = modelOutputSize / modelInputSize
    static let paddedTileOutputSize = patchStrideInput * upscaleFactor * (patchGridSize - 1) + modelOutputSize
    static let outputCropInset = inputPadding * upscaleFactor
    static let fallbackMeanThreshold: Float = 0.20

    private let model: MLModel
    private let inferenceQueue = DispatchQueue(label: "com.arespreview.tile-inference", qos: .userInitiated)

    init() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        self.model = try! MLModel(contentsOf: ModelVersion.v051_2500.compiledURL, configuration: configuration)
    }

    func enhanceLevel1Tile(_ grayscaleTile: CGImage, tileID: String? = nil) async -> EnhancedTileResult? {
        await withCheckedContinuation { continuation in
            inferenceQueue.async {
                guard let result = self.runLevel1Enhancement(grayscaleTile, tileID: tileID) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: EnhancedTileResult(image: result.image, elapsedMs: result.inferenceMs))
            }
        }
    }

    /// Single-level patch enhancement for Level 1 tiles (~2371×2371).
    /// Resizes to 992×992, runs a 9×9 grid of 128×128 patches (81 model passes),
    /// producing ~4000×4000 output, then downsizes to 2048×2048.
    /// ~0.5 seconds per tile, ~20 seconds for all 40 tiles.
    private func runLevel1Enhancement(_ grayscaleTile: CGImage, tileID: String?) -> (image: CGImage, inferenceMs: Double)? {
        let inputW = grayscaleTile.width
        let inputH = grayscaleTile.height

        // For small inputs, fall back to single-pass
        if inputW <= Self.tileInputSize && inputH <= Self.tileInputSize {
            return runTileEnhancement(grayscaleTile, tileID: tileID)
        }

        // Resize to intermediate that produces a clean 9×9 grid
        let intermediateSize = 992
        guard let resized = Self.resizeImage(
            grayscaleTile,
            to: CGSize(width: intermediateSize, height: intermediateSize),
            grayscale: true,
            interpolation: .high
        ) else { return nil }

        guard let fullGrayBytes = Self.grayBytes(from: resized) else { return nil }

        let l1Padding = 16
        let paddedSize = intermediateSize + l1Padding * 2 // 1024
        let l1GridSize = 9
        let l1Stride = (paddedSize - Self.modelInputSize) / (l1GridSize - 1) // 112

        let paddedGrayBytes = Self.mirrorPad(
            fullGrayBytes,
            width: intermediateSize,
            height: intermediateSize,
            padding: l1Padding
        )

        let patchWeights = Self.patchWeights128(stride: l1Stride, gridSize: l1GridSize)
        let l1PaddedOutputSize = l1Stride * Self.upscaleFactor * (l1GridSize - 1) + Self.modelOutputSize
        var accumulated = [Float](repeating: 0, count: l1PaddedOutputSize * l1PaddedOutputSize)
        var accumulatedWeights = [Float](repeating: 0, count: l1PaddedOutputSize * l1PaddedOutputSize)

        let patchPixels = Self.modelInputSize * Self.modelInputSize
        guard let inputArray = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: Self.modelInputSize), NSNumber(value: Self.modelInputSize)],
            dataType: .float16
        ) else { return nil }
        let inputPointer = inputArray.dataPointer.bindMemory(to: Float16.self, capacity: 3 * patchPixels)

        var lut = [Float16](repeating: 0, count: 256)
        for i in 0..<256 { lut[i] = Float16(Float(i) / 255.0) }

        var totalInferenceMs: Double = 0

        for row in 0..<l1GridSize {
            for column in 0..<l1GridSize {
                let cropX = column * l1Stride
                let cropY = row * l1Stride

                for py in 0..<Self.modelInputSize {
                    for px in 0..<Self.modelInputSize {
                        let srcIdx = (cropY + py) * paddedSize + (cropX + px)
                        let dstIdx = py * Self.modelInputSize + px
                        let value = lut[Int(paddedGrayBytes[srcIdx])]
                        inputPointer[dstIdx] = value
                        inputPointer[patchPixels + dstIdx] = value
                        inputPointer[2 * patchPixels + dstIdx] = value
                    }
                }

                guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
                    "input": MLFeatureValue(multiArray: inputArray)
                ]) else { return nil }

                let predictStart = CFAbsoluteTimeGetCurrent()
                guard let output = try? model.prediction(from: provider) else { return nil }
                totalInferenceMs += (CFAbsoluteTimeGetCurrent() - predictStart) * 1000

                guard let outputArray = output.featureValue(for: "output")?.multiArrayValue else { return nil }

                let patchBytes: [UInt8]
                if let enhancedPatchBytes = Self.multiArrayToGrayBytes(
                    outputArray,
                    width: Self.modelOutputSize,
                    height: Self.modelOutputSize
                ) {
                    let patchMean = Float(enhancedPatchBytes.reduce(0, { $0 + Int($1) })) / Float(enhancedPatchBytes.count * 255)
                    if patchMean < Self.fallbackMeanThreshold {
                        guard let paddedTile = Self.grayscaleImage(from: paddedGrayBytes, width: paddedSize, height: paddedSize),
                              let inputCrop = paddedTile.cropping(to: CGRect(x: cropX, y: cropY, width: Self.modelInputSize, height: Self.modelInputSize)),
                              let upscaled = Self.resizeImage(inputCrop, to: CGSize(width: Self.modelOutputSize, height: Self.modelOutputSize), grayscale: true, interpolation: .high),
                              let fallbackBytes = Self.grayBytes(from: upscaled) else { return nil }
                        patchBytes = fallbackBytes
                    } else {
                        patchBytes = enhancedPatchBytes
                    }
                } else {
                    return nil
                }

                let outputX = column * l1Stride * Self.upscaleFactor
                let outputY = row * l1Stride * Self.upscaleFactor
                for py in 0..<Self.modelOutputSize {
                    let patchRow = py * Self.modelOutputSize
                    let outputRow = (outputY + py) * l1PaddedOutputSize + outputX
                    for px in 0..<Self.modelOutputSize {
                        let patchIndex = patchRow + px
                        let outputIndex = outputRow + px
                        let weight = patchWeights[patchIndex]
                        accumulated[outputIndex] += Float(patchBytes[patchIndex]) * weight
                        accumulatedWeights[outputIndex] += weight
                    }
                }
            }
        }

        let l1OutputCropInset = l1Padding * Self.upscaleFactor
        let l1CroppedSize = intermediateSize * Self.upscaleFactor // 3968
        var croppedBytes = [UInt8](repeating: 0, count: l1CroppedSize * l1CroppedSize)
        for y in 0..<l1CroppedSize {
            let sourceY = y + l1OutputCropInset
            for x in 0..<l1CroppedSize {
                let sourceIndex = sourceY * l1PaddedOutputSize + x + l1OutputCropInset
                let weight = max(accumulatedWeights[sourceIndex], 0.0001)
                let value = accumulated[sourceIndex] / weight
                croppedBytes[y * l1CroppedSize + x] = UInt8(max(0, min(255, Int(value.rounded()))))
            }
        }

        // Downsize to 2048 for display
        guard let fullRes = Self.grayscaleImage(from: croppedBytes, width: l1CroppedSize, height: l1CroppedSize),
              let finalImage = Self.resizeImage(fullRes, to: CGSize(width: 2048, height: 2048), grayscale: true) else {
            return nil
        }

        return (finalImage, totalInferenceMs)
    }

    /// Hann-window patch weights for a given stride and grid size (128×128 model output patches).
    private static func patchWeights128(stride: Int, gridSize: Int) -> [Float] {
        let edgeBlend = max(modelOutputSize - stride * upscaleFactor, 1)
        var axis = [Float](repeating: 1, count: modelOutputSize)
        for index in 0..<modelOutputSize {
            let left = Float(index + 1) / Float(edgeBlend)
            let right = Float(modelOutputSize - index) / Float(edgeBlend)
            axis[index] = min(1, left, right)
        }
        var weights = [Float](repeating: 0, count: modelOutputSize * modelOutputSize)
        for y in 0..<modelOutputSize {
            for x in 0..<modelOutputSize {
                weights[y * modelOutputSize + x] = axis[y] * axis[x]
            }
        }
        return weights
    }

    func enhanceLevel2Tile(_ grayscaleTile: CGImage, tileID: String? = nil) async -> EnhancedTileResult? {
        await withCheckedContinuation { continuation in
            inferenceQueue.async {
                guard let result = self.runTileEnhancement(grayscaleTile, tileID: tileID) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: EnhancedTileResult(image: result.image, elapsedMs: result.inferenceMs))
            }
        }
    }

    private func runTileEnhancement(_ grayscaleTile: CGImage, tileID: String?) -> (image: CGImage, inferenceMs: Double)? {
        guard let normalizedTile = Self.resizeImage(
            grayscaleTile,
            to: CGSize(width: Self.tileInputSize, height: Self.tileInputSize),
            grayscale: true,
            interpolation: .high
        ) else { return nil }

        guard let fullGrayBytes = Self.grayBytes(from: normalizedTile) else { return nil }
        let paddedGrayBytes = Self.mirrorPad(
            fullGrayBytes,
            width: Self.tileInputSize,
            height: Self.tileInputSize,
            padding: Self.inputPadding
        )
        guard let paddedTile = Self.grayscaleImage(
            from: paddedGrayBytes,
            width: Self.paddedTileInputSize,
            height: Self.paddedTileInputSize
        ) else { return nil }

        let patchWeights = Self.patchWeights
        var accumulated = [Float](repeating: 0, count: Self.paddedTileOutputSize * Self.paddedTileOutputSize)
        var accumulatedWeights = [Float](repeating: 0, count: Self.paddedTileOutputSize * Self.paddedTileOutputSize)

        let patchPixels = Self.modelInputSize * Self.modelInputSize
        guard let inputArray = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: Self.modelInputSize), NSNumber(value: Self.modelInputSize)],
            dataType: .float16
        ) else { return nil }
        let inputPointer = inputArray.dataPointer.bindMemory(to: Float16.self, capacity: 3 * patchPixels)

        var lut = [Float16](repeating: 0, count: 256)
        for i in 0..<256 { lut[i] = Float16(Float(i) / 255.0) }

        var totalInferenceMs: Double = 0

        for row in 0..<Self.patchGridSize {
            for column in 0..<Self.patchGridSize {
                let cropX = column * Self.patchStrideInput
                let cropY = row * Self.patchStrideInput

                for py in 0..<Self.modelInputSize {
                    for px in 0..<Self.modelInputSize {
                        let srcIdx = (cropY + py) * Self.paddedTileInputSize + (cropX + px)
                        let dstIdx = py * Self.modelInputSize + px
                        let value = lut[Int(paddedGrayBytes[srcIdx])]
                        inputPointer[dstIdx] = value
                        inputPointer[patchPixels + dstIdx] = value
                        inputPointer[2 * patchPixels + dstIdx] = value
                    }
                }

                guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
                    "input": MLFeatureValue(multiArray: inputArray)
                ]) else { return nil }

                let predictStart = CFAbsoluteTimeGetCurrent()
                guard let output = try? model.prediction(from: provider) else { return nil }
                totalInferenceMs += (CFAbsoluteTimeGetCurrent() - predictStart) * 1000

                guard let outputArray = output.featureValue(for: "output")?.multiArrayValue else { return nil }

                let patchBytes: [UInt8]
                if let enhancedPatchBytes = Self.multiArrayToGrayBytes(
                    outputArray,
                    width: Self.modelOutputSize,
                    height: Self.modelOutputSize
                ) {
                    let patchMean = Float(enhancedPatchBytes.reduce(0, { $0 + Int($1) })) / Float(enhancedPatchBytes.count * 255)
                    if patchMean < Self.fallbackMeanThreshold,
                       let inputCrop = paddedTile.cropping(to: CGRect(x: cropX, y: cropY, width: Self.modelInputSize, height: Self.modelInputSize)),
                       let upscaled = Self.resizeImage(
                        inputCrop,
                        to: CGSize(width: Self.modelOutputSize, height: Self.modelOutputSize),
                        grayscale: true,
                        interpolation: .high
                       ),
                       let fallbackBytes = Self.grayBytes(from: upscaled) {
                        patchBytes = fallbackBytes
                    } else {
                        patchBytes = enhancedPatchBytes
                    }
                } else {
                    return nil
                }

                let outputX = column * Self.patchStrideInput * Self.upscaleFactor
                let outputY = row * Self.patchStrideInput * Self.upscaleFactor
                for py in 0..<Self.modelOutputSize {
                    let patchRow = py * Self.modelOutputSize
                    let outputRow = (outputY + py) * Self.paddedTileOutputSize + outputX
                    for px in 0..<Self.modelOutputSize {
                        let patchIndex = patchRow + px
                        let outputIndex = outputRow + px
                        let weight = patchWeights[patchIndex]
                        accumulated[outputIndex] += Float(patchBytes[patchIndex]) * weight
                        accumulatedWeights[outputIndex] += weight
                    }
                }
            }
        }

        var croppedBytes = [UInt8](repeating: 0, count: Self.tileOutputSize * Self.tileOutputSize)
        for y in 0..<Self.tileOutputSize {
            let sourceY = y + Self.outputCropInset
            for x in 0..<Self.tileOutputSize {
                let sourceIndex = sourceY * Self.paddedTileOutputSize + x + Self.outputCropInset
                let weight = max(accumulatedWeights[sourceIndex], 0.0001)
                let value = accumulated[sourceIndex] / weight
                croppedBytes[y * Self.tileOutputSize + x] = UInt8(max(0, min(255, Int(value.rounded()))))
            }
        }

        guard let result = Self.grayscaleImage(from: croppedBytes, width: Self.tileOutputSize, height: Self.tileOutputSize) else {
            return nil
        }

        return (result, totalInferenceMs)
    }

    static func makeGrayscaleImage(from image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    static func resizeImage(
        _ image: CGImage,
        to size: CGSize,
        grayscale: Bool = false,
        interpolation: CGInterpolationQuality = .high
    ) -> CGImage? {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)

        let colorSpace = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = grayscale ? width : width * 4
        let bitmapInfo = grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        return context.makeImage()
    }

    static func grayBytes(from image: CGImage) -> [UInt8]? {
        guard let grayscale = makeGrayscaleImage(from: image) else { return nil }

        var bytes = [UInt8](repeating: 0, count: grayscale.width * grayscale.height)
        guard let context = CGContext(
            data: &bytes,
            width: grayscale.width,
            height: grayscale.height,
            bitsPerComponent: 8,
            bytesPerRow: grayscale.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(grayscale, in: CGRect(x: 0, y: 0, width: grayscale.width, height: grayscale.height))
        return bytes
    }

    static func grayscaleImage(from bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func multiArrayToGrayscaleImage(_ array: MLMultiArray, width: Int, height: Int) -> CGImage? {
        guard let bytes = multiArrayToGrayBytes(array, width: width, height: height) else { return nil }
        return grayscaleImage(from: bytes, width: width, height: height)
    }

    static func multiArrayToGrayBytes(_ array: MLMultiArray, width: Int, height: Int) -> [UInt8]? {
        let count = width * height
        var bytes = [UInt8](repeating: 0, count: count)

        if array.dataType == .float16 {
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: 3 * count)
            for index in 0..<count {
                let red = max(0, min(1, Float(pointer[index])))
                let green = max(0, min(1, Float(pointer[count + index])))
                let blue = max(0, min(1, Float(pointer[2 * count + index])))
                bytes[index] = UInt8(((red + green + blue) / 3) * 255)
            }
        } else {
            let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: 3 * count)
            for index in 0..<count {
                let red = max(0, min(1, pointer[index]))
                let green = max(0, min(1, pointer[count + index]))
                let blue = max(0, min(1, pointer[2 * count + index]))
                bytes[index] = UInt8(((red + green + blue) / 3) * 255)
            }
        }

        return bytes
    }

    private static func mirrorPad(_ bytes: [UInt8], width: Int, height: Int, padding: Int) -> [UInt8] {
        let paddedWidth = width + padding * 2
        let paddedHeight = height + padding * 2
        var padded = [UInt8](repeating: 0, count: paddedWidth * paddedHeight)

        for y in 0..<paddedHeight {
            let sourceY = reflectedIndex(y - padding, limit: height)
            for x in 0..<paddedWidth {
                let sourceX = reflectedIndex(x - padding, limit: width)
                padded[y * paddedWidth + x] = bytes[sourceY * width + sourceX]
            }
        }

        return padded
    }

    private static func reflectedIndex(_ index: Int, limit: Int) -> Int {
        guard limit > 1 else { return 0 }

        var value = index
        while value < 0 || value >= limit {
            if value < 0 {
                value = -value - 1
            } else {
                value = 2 * limit - value - 1
            }
        }
        return value
    }

    private static let patchWeights: [Float] = {
        let edgeBlend = max(modelOutputSize - patchStrideInput * upscaleFactor, 1)
        var axis = [Float](repeating: 1, count: modelOutputSize)

        for index in 0..<modelOutputSize {
            let left = Float(index + 1) / Float(edgeBlend)
            let right = Float(modelOutputSize - index) / Float(edgeBlend)
            axis[index] = min(1, left, right)
        }

        var weights = [Float](repeating: 0, count: modelOutputSize * modelOutputSize)
        for y in 0..<modelOutputSize {
            for x in 0..<modelOutputSize {
                weights[y * modelOutputSize + x] = axis[y] * axis[x]
            }
        }

        return weights
    }()
}
