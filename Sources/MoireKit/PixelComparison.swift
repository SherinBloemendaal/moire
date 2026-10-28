import CoreGraphics
import Foundation
import ImageIO

/// An image decoded with ImageIO, with what Moire shows about it.
public struct LoadedImage: @unchecked Sendable {
    public let image: CGImage
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let hasAlpha: Bool
    public let colorSpaceName: String
    /// The uniform type identifier ImageIO found, such as `public.png`.
    public let typeIdentifier: String?
    /// Images in the file; only the first is compared.
    public let frameCount: Int
    /// The EXIF orientation (1 is upright). Pixels are compared as stored, without turning them.
    public let orientation: Int
    public let fileSize: Int64

    public enum LoadError: LocalizedError {
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): "\(name) is not an image this Mac can read."
            }
        }
    }

    public static func load(_ url: URL) throws -> LoadedImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else {
            throw LoadError.unreadable(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return LoadedImage(
            image: image,
            typeIdentifier: CGImageSourceGetType(source) as String?,
            frameCount: CGImageSourceGetCount(source),
            orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1,
            fileSize: fileSize
        )
    }

    public init(image: CGImage, typeIdentifier: String? = nil, frameCount: Int = 1, orientation: Int = 1, fileSize: Int64 = 0) {
        self.image = image
        width = image.width
        height = image.height
        bitsPerComponent = image.bitsPerComponent
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        colorSpaceName = image.colorSpace.flatMap { $0.name as String? }.map(Self.shortName) ?? "Unknown"
        self.typeIdentifier = typeIdentifier
        self.frameCount = frameCount
        self.orientation = orientation
        self.fileSize = fileSize
    }

    /// `kCGColorSpaceSRGB` reads as "sRGB", `kCGColorSpaceDisplayP3` as "Display P3".
    static func shortName(_ name: String) -> String {
        let known: [String: String] = [
            CGColorSpace.sRGB as String: "sRGB",
            CGColorSpace.displayP3 as String: "Display P3",
            CGColorSpace.adobeRGB1998 as String: "Adobe RGB",
            CGColorSpace.genericGrayGamma2_2 as String: "Gray",
            CGColorSpace.linearGray as String: "Linear Gray",
            CGColorSpace.linearSRGB as String: "Linear sRGB",
            CGColorSpace.extendedSRGB as String: "Extended sRGB",
            CGColorSpace.genericRGBLinear as String: "Generic RGB Linear",
            CGColorSpace.itur_2020 as String: "Rec. 2020",
            CGColorSpace.itur_709 as String: "Rec. 709",
            CGColorSpace.genericCMYK as String: "CMYK",
        ]
        if let short = known[name] { return short }
        return name.replacingOccurrences(of: "kCGColorSpace", with: "")
    }
}

/// Two images compared pixel by pixel, after decoding both into the same color space, so a PNG
/// and a TIFF with the same picture count as identical even though their bytes differ.
public struct PixelDifference: Sendable {
    /// The compared area: the larger width and height of the two, with both images in the top left corner.
    public let width: Int
    public let height: Int
    public let sameDimensions: Bool
    /// Every decoded pixel is exactly the same.
    public let isIdentical: Bool
    /// Bits per channel the pixels were compared at: 8, or 16 when either image has more than 8.
    public let precision: Int
    /// For each pixel, the largest difference of its red, green, blue or alpha value on a scale
    /// of 0 to 255, rounded up so any change counts at least 1.
    private let deltas: [UInt8]
    /// How many pixels have each delta.
    private let histogram: [Int]

    public enum ComparisonError: LocalizedError {
        case cannotDraw

        public var errorDescription: String? { "The images could not be decoded for comparison." }
    }

    public init(left: CGImage, right: CGImage) throws {
        width = max(left.width, right.width)
        height = max(left.height, right.height)
        sameDimensions = left.width == right.width && left.height == right.height
        precision = max(left.bitsPerComponent, right.bitsPerComponent) > 8 ? 16 : 8
        let space = Self.commonColorSpace(left, right)

        var deltas = [UInt8](repeating: 0, count: width * height)
        var histogram = [Int](repeating: 0, count: 256)
        var identical = true
        if precision == 16 {
            guard let a: [UInt16] = Self.render(left, width: width, height: height, space: space),
                  let b: [UInt16] = Self.render(right, width: width, height: height, space: space)
            else { throw ComparisonError.cannotDraw }
            for pixel in 0..<(width * height) {
                var largest = 0
                for channel in (pixel * 4)..<(pixel * 4 + 4) {
                    largest = max(largest, abs(Int(a[channel]) - Int(b[channel])))
                }
                let delta = UInt8(min(255, (largest + 255) >> 8))
                deltas[pixel] = delta
                histogram[Int(delta)] += 1
                if largest != 0 { identical = false }
            }
        } else {
            guard let a: [UInt8] = Self.render(left, width: width, height: height, space: space),
                  let b: [UInt8] = Self.render(right, width: width, height: height, space: space)
            else { throw ComparisonError.cannotDraw }
            for pixel in 0..<(width * height) {
                var largest = 0
                for channel in (pixel * 4)..<(pixel * 4 + 4) {
                    largest = max(largest, abs(Int(a[channel]) - Int(b[channel])))
                }
                deltas[pixel] = UInt8(largest)
                histogram[largest] += 1
                if largest != 0 { identical = false }
            }
        }
        self.deltas = deltas
        self.histogram = histogram
        isIdentical = identical && sameDimensions
    }

    public var pixelCount: Int { width * height }

    /// Pixels whose delta is above `tolerance` (0 to 255).
    public func differingPixels(tolerance: Int) -> Int {
        let from = min(max(tolerance + 1, 0), 256)
        return histogram[from...].reduce(0, +)
    }

    /// The largest delta of any pixel, 0 when the images are identical.
    public var largestDelta: Int { histogram.lastIndex { $0 > 0 } ?? 0 }

    /// An image of the compared area that is opaque `color` (RGBA, 0 to 255) where a pixel differs
    /// by more than `tolerance`, and clear everywhere else.
    public func mask(tolerance: Int, color: (UInt8, UInt8, UInt8) = (255, 45, 95)) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) where Int(deltas[pixel]) > tolerance {
            pixels[pixel * 4] = color.0
            pixels[pixel * 4 + 1] = color.1
            pixels[pixel * 4 + 2] = color.2
            pixels[pixel * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The color space both images share when it is an RGB one, so nothing is converted and
    /// equal pixels stay exactly equal; otherwise sRGB.
    private static func commonColorSpace(_ left: CGImage, _ right: CGImage) -> CGColorSpace {
        if let a = left.colorSpace, let b = right.colorSpace, a == b, a.model == .rgb, a.supportsOutput {
            return a
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Draws the image into a premultiplied RGBA buffer of the given size, anchored top left.
    private static func render<Channel: FixedWidthInteger & UnsignedInteger>(_ image: CGImage, width: Int, height: Int, space: CGColorSpace) -> [Channel]? {
        var buffer = [Channel](repeating: 0, count: width * height * 4)
        let bits = Channel.bitWidth
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: bits,
                bytesPerRow: width * 4 * bits / 8, space: space, bitmapInfo: info
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
            return true
        }
        return drawn ? buffer : nil
    }
}
