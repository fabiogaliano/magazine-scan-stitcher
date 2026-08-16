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
            // Use conservative content bounds and pad generously; the UI is the final validation step.
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

        let rect = CGRect(
            x: CGFloat(minX) / CGFloat(w),
            y: CGFloat(minY) / CGFloat(h),
            width: CGFloat(maxX - minX + 1) / CGFloat(w),
            height: CGFloat(maxY - minY + 1) / CGFloat(h)
        )
        var crop = UnitCrop(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        crop.clamp()
        return crop
    }

    static func suggestPairAlignment(_ a: ScanPage, _ b: ScanPage) -> PairAlignment? {
        guard let ca = render(a, applyCrop: true), let cb = render(b, applyCrop: true) else { return nil }
        let maxW = max(ca.width, cb.width)
        let scale = min(1.0, 900.0 / Double(maxW))
        guard let aa = downsampleRGBA(ca, scale: scale), let bb = downsampleRGBA(cb, scale: scale) else { return nil }

        let minWidth = min(aa.width, bb.width)
        let h = min(aa.height, bb.height)
        guard minWidth > 80, h > 80 else { return nil }

        func luma(_ image: RGBAImage, _ x: Int, _ y: Int) -> Int {
            let i = (y * image.width + x) * 4
            return (54 * Int(image.bytes[i]) + 183 * Int(image.bytes[i + 1]) + 19 * Int(image.bytes[i + 2])) >> 8
        }

        // Magazine spreads are scanned as adjacent pieces, so compare only A's right edge to B's left edge.
        // This avoids the false full-page feature matches seen in the real scan while remaining cheap and transparent.
        let fractions: [Double] = stride(from: 0.05, through: 0.22, by: 0.015).map { $0 }
        let maxShift = max(4, Int(Double(h) * 0.045))
        var bestScore = Double.greatestFiniteMagnitude
        var bestOverlap = 0
        var bestShift = 0

        for fraction in fractions {
            let overlap = max(24, Int(Double(minWidth) * fraction))
            let xA = aa.width - overlap
            guard xA >= 0, overlap <= bb.width else { continue }

            for shift in stride(from: -maxShift, through: maxShift, by: 2) {
                let yA0 = max(0, shift)
                let yB0 = max(0, -shift)
                let usableH = min(aa.height - yA0, bb.height - yB0)
                guard usableH > h / 2 else { continue }

                var sum = 0.0
                var count = 0
                let step = 4
                for y in stride(from: 0, to: usableH, by: step) {
                    for x in stride(from: 0, to: overlap, by: step) {
                        let da = luma(aa, xA + x, yA0 + y)
                        let db = luma(bb, x, yB0 + y)
                        sum += Double(abs(da - db))
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                let score = sum / Double(count)
                if score < bestScore {
                    bestScore = score
                    bestOverlap = overlap
                    bestShift = shift
                }
            }
        }

        guard bestOverlap > 0 else { return nil }
        return PairAlignment(
            offsetX: CGFloat(Double(aa.width - bestOverlap) / scale),
            offsetY: CGFloat(Double(bestShift) / scale),
            rotationDegrees: 0,
            opacity: 0.5
        )
    }

    static func renderPair(_ a: ScanPage, _ b: ScanPage, alignment: PairAlignment) -> CGImage? {
        guard let ca = render(a, applyCrop: true), let cb = render(b, applyCrop: true) else { return nil }
        let ia = CIImage(cgImage: ca)
        var ib = CIImage(cgImage: cb)
        // SwiftUI's screen coordinate rotation is opposite Core Image's Cartesian rotation.
        ib = rotate(ib, degrees: -alignment.rotationDegrees)
        ib = ib.transformed(by: CGAffineTransform(translationX: alignment.offsetX, y: -alignment.offsetY))

        let union = ia.extent.union(ib.extent).integral
        let shift = CGAffineTransform(translationX: -union.minX, y: -union.minY)
        let base = ia.transformed(by: shift)
        let overlay = ib.transformed(by: shift)
        let outputExtent = CGRect(origin: .zero, size: union.size)

        let transparent = CIImage(color: .clear).cropped(to: outputExtent)
        let withA = base.composited(over: transparent)
        let final = overlay.composited(over: withA)
        return context.createCGImage(final, from: outputExtent)
    }

    static func write(_ image: CGImage, to url: URL, properties: [CFString: Any]) throws {
        let type: CFString
        switch url.pathExtension.lowercased() {
        case "png": type = UTType.png.identifier as CFString
        case "jpg", "jpeg": type = UTType.jpeg.identifier as CFString
        default: type = UTType.tiff.identifier as CFString
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw ScanError.exportFailed
        }
        var outputProps = properties
        outputProps[kCGImagePropertyOrientation] = 1
        if type == UTType.jpeg.identifier as CFString {
            outputProps[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destination, image, outputProps as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScanError.exportFailed }
    }

    private struct RGBAImage { let width: Int; let height: Int; let bytes: [UInt8] }

    private static func downsampleRGBA(_ image: CGImage, maxDimension: Int) -> RGBAImage? {
        let scale = min(1.0, Double(maxDimension) / Double(max(image.width, image.height)))
        return downsampleRGBA(image, scale: scale)
    }

    private static func downsampleRGBA(_ image: CGImage, scale: Double) -> RGBAImage? {
        let clampedScale = min(1.0, max(0.01, scale))
        let width = max(1, Int(Double(image.width) * clampedScale))
        let height = max(1, Int(Double(image.height) * clampedScale))
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
