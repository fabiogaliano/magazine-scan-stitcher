import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO

struct UnitCrop: Equatable, Codable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 1
    var height: CGFloat = 1

    static let full = UnitCrop()

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    mutating func clamp() {
        x = min(max(x, 0), 0.98)
        y = min(max(y, 0), 0.98)
        width = min(max(width, 0.02), 1 - x)
        height = min(max(height, 0.02), 1 - y)
    }
}

@MainActor
final class ScanPage: ObservableObject, Identifiable {
    let id = UUID()
    let sourceURL: URL
    let sourcePageIndex: Int
    let original: CGImage
    let sourceProperties: [CFString: Any]

    @Published var crop: UnitCrop = .full
    @Published var quarterTurns: Int = 0
    @Published var fineRotationDegrees: Double = 0
    @Published var cropValidated = false

    init(sourceURL: URL, sourcePageIndex: Int, original: CGImage, sourceProperties: [CFString: Any]) {
        self.sourceURL = sourceURL
        self.sourcePageIndex = sourcePageIndex
        self.original = original
        self.sourceProperties = sourceProperties
    }

    var title: String {
        if sourcePageIndex == 0 { return sourceURL.lastPathComponent }
        return "\(sourceURL.lastPathComponent) · page \(sourcePageIndex + 1)"
    }

    func rotateLeft() {
        quarterTurns = (quarterTurns + 3) % 4
        crop = .full
        cropValidated = false
    }

    func rotateRight() {
        quarterTurns = (quarterTurns + 1) % 4
        crop = .full
        cropValidated = false
    }

    func resetEdits() {
        crop = .full
        quarterTurns = 0
        fineRotationDegrees = 0
        cropValidated = false
    }
}

struct PairAlignment: Equatable {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var rotationDegrees: Double = 0
    var opacity: Double = 0.50

    mutating func reset(baseWidth: CGFloat) {
        offsetX = baseWidth * 0.90
        offsetY = 0
        rotationDegrees = 0
        opacity = 0.50
    }
}

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case page = "Page"
    case align = "Align Pair"
    var id: Self { self }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var pages: [ScanPage] = []
    @Published var selectedPageID: UUID?
    @Published var mode: WorkspaceMode = .page
    @Published var pairAlignment = PairAlignment()
    @Published var statusMessage = "Import a scan or connect a scanner."
    @Published var lastError: String?

    var selectedPage: ScanPage? {
        pages.first(where: { $0.id == selectedPageID })
    }

    var canAlignPair: Bool { pages.count >= 2 }

    func addFiles(_ urls: [URL]) {
        do {
            var added: [ScanPage] = []
            for url in urls {
                added.append(contentsOf: try ImagePipeline.loadPages(from: url))
            }
            pages.append(contentsOf: added)
            if selectedPageID == nil { selectedPageID = added.first?.id }
            if pages.count >= 2, pairAlignment.offsetX == 0,
               let first = pages.first,
               let rendered = ImagePipeline.render(first, applyCrop: true) {
                pairAlignment.reset(baseWidth: CGFloat(rendered.width))
            }
            statusMessage = added.count == 1 ? "1 page added." : "\(added.count) pages added."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.tiff, .png, .jpeg]
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func removeSelected() {
        guard let selectedPageID,
              let index = pages.firstIndex(where: { $0.id == selectedPageID }) else { return }
        pages.remove(at: index)
        self.selectedPageID = pages.first?.id
        if pages.count < 2 { mode = .page }
    }

    func exportCurrent() {
        guard let page = selectedPage else { return }
        do {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = mode == .align && canAlignPair ? "spread.tiff" : "scan.tiff"
            panel.allowedContentTypes = [.tiff, .png, .jpeg]
            guard panel.runModal() == .OK, let url = panel.url else { return }

            if mode == .align, canAlignPair {
                guard let image = ImagePipeline.renderPair(pages[0], pages[1], alignment: pairAlignment) else {
                    throw ScanError.renderFailed
                }
                try ImagePipeline.write(image, to: url, properties: pages[0].sourceProperties)
            } else {
                guard let image = ImagePipeline.render(page, applyCrop: true) else {
                    throw ScanError.renderFailed
                }
                try ImagePipeline.write(image, to: url, properties: page.sourceProperties)
            }
            statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            lastError = error.localizedDescription
        }
    }
}

enum ScanError: LocalizedError {
    case unreadableImage(URL)
    case renderFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let url): return "Could not read \(url.lastPathComponent)."
        case .renderFailed: return "Could not render the edited scan."
        case .exportFailed: return "Could not write the exported scan."
        }
    }
}
