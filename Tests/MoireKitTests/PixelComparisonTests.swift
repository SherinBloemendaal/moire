import CoreGraphics
import Foundation
import ImageIO
@testable import MoireKit
import Testing

/// A small picture with a gradient, so every pixel has its own color.
private func makeImage(width: Int = 32, height: Int = 24, bits: Int = 8, change: ((Int, Int), UInt8)? = nil) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let bytesPerChannel = bits / 8
    var info = CGImageAlphaInfo.premultipliedLast.rawValue
    if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: bits,
        bytesPerRow: width * 4 * bytesPerChannel, space: space, bitmapInfo: info
    ))
    for y in 0..<height {
        for x in 0..<width {
            context.setFillColor(CGColor(srgbRed: Double(x) / Double(width), green: Double(y) / Double(height), blue: 0.5, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    var image = try #require(context.makeImage())
    if let ((x, y), value) = change {
        // Rewrites one channel of one pixel straight in the buffer, by an exact amount.
        let data = try #require(image.dataProvider?.data as Data?)
        var bytes = [UInt8](data)
        let row = image.bytesPerRow
        let index = y * row + x * 4 * bytesPerChannel
        bytes[index] = bytes[index] &+ value
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: bits, bitsPerPixel: 32 * bytesPerChannel, bytesPerRow: row,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ))
    }
    return image
}

private func write(_ image: CGImage, as type: String, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Suite struct PixelComparisonTests {
    @Test func `the same picture as PNG and TIFF has identical pixels`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moire-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appending(path: "a.png")
        let tiff = folder.appending(path: "a.tiff")
        let image = try makeImage()
        try write(image, as: "public.png", to: png)
        try write(image, as: "public.tiff", to: tiff)
        #expect(try Data(contentsOf: png) != Data(contentsOf: tiff))

        let left = try LoadedImage.load(png)
        let right = try LoadedImage.load(tiff)
        #expect(left.width == 32 && left.height == 24)
        #expect(left.typeIdentifier == "public.png")
        #expect(left.fileSize > 0)
        let difference = try PixelDifference(left: left.image, right: right.image)
        #expect(difference.isIdentical)
        #expect(difference.differingPixels(tolerance: 0) == 0)
        #expect(FileKind.detect(png) == .image)
    }

    @Test func `formats without a known signature are found through ImageIO`() throws {
        let type = "com.truevision.tga-image"
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type)
        try #require(supported, "ImageIO cannot write TGA on this Mac")
        let url = FileManager.default.temporaryDirectory.appending(path: "moire-\(UUID().uuidString).tga")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(try makeImage(), as: type, to: url)
        #expect(FileKind.sniff(header: try FileKind.readHeader(of: url), fileName: url.lastPathComponent) == .binary)
        #expect(FileKind.detect(url) == .image)
    }

    @Test func `one changed pixel is found and the tolerance hides a small change`() throws {
        let difference = try PixelDifference(left: try makeImage(), right: try makeImage(change: ((5, 7), 3)))
        #expect(!difference.isIdentical)
        #expect(difference.sameDimensions)
        #expect(difference.differingPixels(tolerance: 0) == 1)
        #expect(difference.differingPixels(tolerance: 2) == 1)
        #expect(difference.differingPixels(tolerance: 3) == 0)
        #expect(difference.largestDelta == 3)
    }

    @Test func `the mask marks only the differing pixel`() throws {
        let difference = try PixelDifference(left: try makeImage(), right: try makeImage(change: ((5, 7), 40)))
        let mask = try #require(difference.mask(tolerance: 0))
        #expect(mask.width == 32 && mask.height == 24)
        let bytes = [UInt8](try #require(mask.dataProvider?.data as Data?))
        let opaque = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] == 255 }
        #expect(opaque == [(7 * 32 + 5) * 4 + 3])
        #expect(difference.mask(tolerance: 40).flatMap { $0.dataProvider?.data as Data? }.map { [UInt8]($0).allSatisfy { $0 == 0 } } == true)
    }

    @Test func `different sizes are compared from the top left`() throws {
        let difference = try PixelDifference(left: try makeImage(width: 32, height: 24), right: try makeImage(width: 32, height: 30))
        #expect(!difference.sameDimensions)
        #expect(!difference.isIdentical)
        #expect(difference.width == 32 && difference.height == 30)
        // The extra rows exist on one side only. The gradient is scaled to each height, so most
        // shared rows differ as well; at least the extra rows must count.
        #expect(difference.differingPixels(tolerance: 0) >= 32 * 6)
    }

    @Test func `sixteen bit images keep the smallest change`() throws {
        let difference = try PixelDifference(left: try makeImage(bits: 16), right: try makeImage(bits: 16, change: ((1, 1), 1)))
        #expect(difference.precision == 16)
        #expect(!difference.isIdentical)
        #expect(difference.differingPixels(tolerance: 0) == 1)
        #expect(difference.differingPixels(tolerance: 1) == 0)
    }
}
