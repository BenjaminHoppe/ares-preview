import Metal
import CoreGraphics

/// GPU-accelerated Lab colour space compositing engine.
/// Combines B&W luminance tiles (L channel) with Viking mosaic colour (a*, b* channels)
/// using a Metal compute shader. Registration correction is applied via the chroma crop.
final class ColourEngine: @unchecked Sendable {
    static let shared = ColourEngine()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let chromaLock = NSLock()
    private var chromaTexture: MTLTexture?

    /// Geographic area the chroma texture covers (standard CTX coordinates).
    /// Sized to cover the full tile region with margin for sub-pixel sampling.
    static let chromaGeoRect = GeoRect(lonMin: 308, lonMax: 352, latMin: 4, latMax: 32)

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: Self.metalSource, options: nil)
        let function = library.makeFunction(name: "labComposite")!
        pipelineState = try! device.makeComputePipelineState(function: function)
    }

    /// Prepare the chroma lookup texture from the Viking mosaic.
    /// Thread-safe; no-op after the first successful call.
    /// Viking registration correction (-1.906 lon, +0.812 lat) is applied by VikingMosaicProvider.
    func prepareChromaTexture() {
        chromaLock.lock()
        defer { chromaLock.unlock() }
        guard chromaTexture == nil else { return }
        guard let crop = VikingMosaicProvider.crop(
            rect: Self.chromaGeoRect, targetWidth: 2048
        ) else {
            return
        }
        chromaTexture = makeTexture(from: crop)
    }

    /// Composite a B&W tile with Viking colour using Lab colour space on the GPU.
    /// Returns nil if chroma texture is not loaded or compositing fails.
    func composite(luminanceTile: CGImage, tileRect: GeoRect) -> CGImage? {
        guard let chromaTexture else { return nil }
        guard let lumTexture = makeTexture(from: luminanceTile) else { return nil }

        let outW = luminanceTile.width
        let outH = luminanceTile.height

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: outW, height: outH, mipmapped: false
        )
        outDesc.usage = [.shaderWrite]
        guard let outTex = device.makeTexture(descriptor: outDesc) else { return nil }

        // UV mapping: tile geo rect → normalised coordinates in the chroma texture
        var params = LabParams(
            chromaUVMin: SIMD2(
                Float((tileRect.lonMin - Self.chromaGeoRect.lonMin) / Self.chromaGeoRect.width),
                Float((Self.chromaGeoRect.latMax - tileRect.latMax) / Self.chromaGeoRect.height)
            ),
            chromaUVMax: SIMD2(
                Float((tileRect.lonMax - Self.chromaGeoRect.lonMin) / Self.chromaGeoRect.width),
                Float((Self.chromaGeoRect.latMax - tileRect.latMin) / Self.chromaGeoRect.height)
            )
        )

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipelineState)
        enc.setTexture(lumTexture, index: 0)
        enc.setTexture(chromaTexture, index: 1)
        enc.setTexture(outTex, index: 2)
        enc.setBytes(&params, length: MemoryLayout<LabParams>.stride, index: 0)

        let tgs = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(
            MTLSize(width: (outW + 15) / 16, height: (outH + 15) / 16, depth: 1),
            threadsPerThreadgroup: tgs
        )
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        return readTexture(outTex)
    }

    // MARK: - Texture I/O

    private func makeTexture(from image: CGImage) -> MTLTexture? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: pixels, bytesPerRow: w * 4)
        return tex
    }

    private func readTexture(_ texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&pixels, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: - Metal Shader

    private struct LabParams {
        var chromaUVMin: SIMD2<Float>
        var chromaUVMax: SIMD2<Float>
    }

    // swiftlint:disable all
    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct LabParams {
        float2 chromaUVMin;
        float2 chromaUVMax;
    };

    inline float srgbToLinear(float c) {
        return c <= 0.04045f ? c / 12.92f : pow((c + 0.055f) / 1.055f, 2.4f);
    }

    inline float linearToSrgb(float c) {
        float v = max(c, 0.0f);
        return v <= 0.0031308f ? 12.92f * v : 1.055f * pow(v, 1.0f / 2.4f) - 0.055f;
    }

    inline float labF(float t) {
        return t > (216.0f / 24389.0f)
            ? pow(t, 1.0f / 3.0f)
            : (24389.0f / 27.0f * t + 16.0f) / 116.0f;
    }

    inline float labFInv(float t) {
        float t3 = t * t * t;
        return t3 > (216.0f / 24389.0f)
            ? t3
            : (116.0f * t - 16.0f) / (24389.0f / 27.0f);
    }

    kernel void labComposite(
        texture2d<float, access::read>   luminance [[texture(0)]],
        texture2d<float, access::sample> chroma    [[texture(1)]],
        texture2d<float, access::write>  output    [[texture(2)]],
        constant LabParams&              params    [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint outW = output.get_width();
        uint outH = output.get_height();
        if (gid.x >= outW || gid.y >= outH) return;

        const float whiteX = 0.95047f;
        const float whiteY = 1.0f;
        const float whiteZ = 1.08883f;

        // B&W tile pixel → perceptual lightness (L channel)
        float gray = luminance.read(gid).r;
        float grayLinear = srgbToLinear(gray);
        float L = 116.0f * labF(grayLinear / whiteY) - 16.0f;

        // Map pixel position to normalised UV in chroma texture
        float u = params.chromaUVMin.x
            + (float(gid.x) + 0.5f) / float(outW)
            * (params.chromaUVMax.x - params.chromaUVMin.x);
        float v = params.chromaUVMin.y
            + (float(gid.y) + 0.5f) / float(outH)
            * (params.chromaUVMax.y - params.chromaUVMin.y);

        constexpr sampler chromaSampler(address::clamp_to_edge, filter::linear);
        float4 chr = chroma.sample(chromaSampler, float2(u, v));

        // Viking RGB → XYZ → Lab (extract a*, b* chroma channels)
        float cr = srgbToLinear(chr.r);
        float cg = srgbToLinear(chr.g);
        float cb = srgbToLinear(chr.b);

        float cx = (0.4124564f * cr + 0.3575761f * cg + 0.1804375f * cb) / whiteX;
        float cy = (0.2126729f * cr + 0.7151522f * cg + 0.0721750f * cb) / whiteY;
        float cz = (0.0193339f * cr + 0.1191920f * cg + 0.9503041f * cb) / whiteZ;

        float a_star = 500.0f * (labF(cx) - labF(cy));
        float b_star = 200.0f * (labF(cy) - labF(cz));

        // Warm-shift: force minimum warmth so nothing stays grey/blue
        // Viking mosaic has cool regions that don't look like Mars
        a_star = max(a_star, 14.0f);   // minimum redness
        b_star = max(b_star, 22.0f);  // minimum yellowness

        // Combine: CTX L + Viking a*,b* → XYZ → linear RGB → sRGB
        float fy = (L + 16.0f) / 116.0f;
        float fx = fy + a_star / 500.0f;
        float fz = fy - b_star / 200.0f;

        float x = whiteX * labFInv(fx);
        float y = whiteY * labFInv(fy);
        float z = whiteZ * labFInv(fz);

        float lr =  3.2404542f * x - 1.5371385f * y - 0.4985314f * z;
        float lg = -0.9692660f * x + 1.8760108f * y + 0.0415560f * z;
        float lb =  0.0556434f * x - 0.2040259f * y + 1.0572252f * z;

        output.write(float4(
            clamp(linearToSrgb(lr), 0.0f, 1.0f),
            clamp(linearToSrgb(lg), 0.0f, 1.0f),
            clamp(linearToSrgb(lb), 0.0f, 1.0f),
            1.0f
        ), gid);
    }
    """
    // swiftlint:enable all
}
