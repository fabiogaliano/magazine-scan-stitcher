import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum ImagePipeline {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func loadPages(from url: URL) throws -> [ScanPage] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ScanError.unreadableImage(url)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ScanError.unreadableImage(url) }

        var pages: [ScanPage] = []
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: true] as CFDictionary) else { continue }
            let props = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            pages.append(ScanPage(sourceURL: url, sourcePageIndex: index, original: image, sourceProperties: props))
        }
        guard !pages.isEmpty else { throw ScanError.unreadableImage(url) }
        return pages
    }

    static func previewImage(_ page: ScanPage) -> NSImage? {
        guard let cg = render(page, applyCrop: false) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func editedImage(_ page: ScanPage) -> NSImage? {
        guard let cg = render(page, applyCrop: true) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func render(_ page: ScanPage, applyCrop: Bool) -> CGImage? {
        var image = CIImage(cgImage: page.original)
        let totalDegrees = Double(page.quarterTurns) * 90 + page.fineRotationDegrees
        image = rotate(image, degrees: totalDegrees)

        if applyCrop {
            let c = page.crop
            let e = image.extent
            let cropRect = CGRect(
                x: e.minX + c.x * e.width,
                y: e.minY + (1 - c.y - c.height) * e.height,
                width: c.width * e.width,
                height: c.height * e.height
            ).intersection(e)
            image = image.cropped(to: cropRect)
        }
        let extent = image.extent.integral
        return context.createCGImage(image, from: extent)
    }

    private static func rotate(_ image: CIImage, degrees: Double) -> CIImage {
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        guard abs(normalized) > 0.0001 else { return image }
        let radians = CGFloat(normalized * .pi / 180)
        let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)
        let rotated = image.transformed(by: transform)
        let e = rotated.extent
        return rotated.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    static func suggestCrop(for page: ScanPage) -> UnitCrop {
        guard let cg = render(page, applyCrop: false),
              let sample = downsampleRGBA(cg, maxDimension: 720) else { return .full }

        let w = sample.width, h = sample.height
        let px = sample.bytes
        func luma(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
        }

        var border: [Double] = []
        let step = max(1, min(w, h) / 180)
        for x in stride(from: 0, to: w, by: step) {
            border.append(luma(x, 0)); border.append(luma(x, h - 1))
        }
        for y in stride(from: 0, to: h, by: step) {
            border.append(luma(0, y)); border.append(luma(w - 1, y))
        }
        border.sort()
        let borderMedian = border[border.count / 2]

        var minX = w, minY = h, maxX = -1, maxY = -1
        if borderMedian < 175 {
            let threshold = min(235.0, borderMedian + 42.0)
            for y in 0..<h {
                for x in 0..<w where luma(x, y) > threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        } else {
            let threshold = max(0.0, borderMedian - 22.0)
            for y in 0..<h {
                for x in 0..<w where luma(x, y) < threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            let padX = Int(Double(w) * 0.035)
            let padY = Int(Double(h) * 0.035)
            minX -= padX; maxX += padX; minY -= padY; maxY += padY
        }

        guard maxX >= minX, maxY >= minY else { return .full }
        minX = max(0, minX); minY = max(0, minY)
        maxX = min(w - 1, maxX); maxY = min(h - 1, maxY)

        var crop = UnitCrop(
            x: CGFloat(minX) / CGFloat(w),
            y: CGFloat(minY) / CGFloat(h),
            width: CGFloat(maxX - minX + 1) / CGFloat(w),
            height: CGFloat(maxY - minY + 1) / CGFloat(h)
        )
        crop.clamp()
        return crop
    }

    static func renderPair(_ a: ScanPage, _ b: ScanPage, alignment: PairAlignment) -> CGImage? {
        guard let ca = render(a, applyCrop: true), let cb = render(b, applyCrop: true) else { return nil }
        let ia = CIImage(cgImage: ca)
        var ib = CIImage(cgImage: cb)
        ib = rotate(ib, degrees: alignment.rotationDegrees)
        ib = ib.transformed(by: CGAffineTransform(translationX: alignment.offsetX, y: -alignment.offsetY))

        let union = ia.extent.union(ib.extent).integral
        let shift = CGAffineTransform(translationX: -union.minX, y: -union.minY)
        let base = ia.transformed(by: shift)
        let overlay = ib.transformed(by: shift)
        let outputExtent = CGRect(origin: .zero, size: union.size)

        let transparent = CIImage(color: CIColor.clear).cropped(to: outputExtent)
        let withA = base.composited(over: transparent)
        let final = overlay.composited(over: withA)
        return context.createCGImage(final, from: outputExtent)
    }

    static func write(_ image: CGImage, to url: URL, properties: [CFString: Any]) throws {
        let ext = url.pathExtension.lowercased()
        let type: CFString
        switch ext {
        case "png": type = UTType.png.identifier as CFString
        case "jpg", "jpeg": type = UTType.jpeg.identifier as CFString
        default: type = UTType.tiff.identifier as CFString
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw ScanError.exportFailed
        }
        var outputProps = properties
        outputProps[kCGImagePropertyOrientation] = 1
        if ext == "jpg" || ext == "jpeg" {
            outputProps[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destination, image, outputProps as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScanError.exportFailed }
    }

    private struct RGBAImage { let width: Int; let height: Int; let bytes: [UInt8] }

    private static func downsampleRGBA(_ image: CGImage, maxDimension: Int) -> RGBAImage? {
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBAImage(width: width, height: height, bytes: bytes)
    }
}
