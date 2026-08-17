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

    mutating func reset(offsetX: CGFloat) {
        self.offsetX = offsetX
        offsetY = 0
        rotationDegrees = 0
        opacity = 0.50
    }

    /// Returns the same visual relationship expressed with the old moving page as the new fixed page.
    /// PairAlignment positions the moving image by its top-left corner and rotates around its center.
    func inverted(fixedSize: CGSize, movingSize: CGSize) -> PairAlignment {
        let radians = CGFloat(rotationDegrees * .pi / 180)
        let c = cos(radians)
        let s = sin(radians)
        let fixedCenter = CGPoint(x: fixedSize.width / 2, y: fixedSize.height / 2)
        let movingCenter = CGPoint(x: movingSize.width / 2, y: movingSize.height / 2)

        let vx = fixedCenter.x - movingCenter.x - offsetX
        let vy = fixedCenter.y - movingCenter.y - offsetY
        let rx = c * vx + s * vy
        let ry = -s * vx + c * vy

        return PairAlignment(
            offsetX: rx + movingCenter.x - fixedCenter.x,
            offsetY: ry + movingCenter.y - fixedCenter.y,
            rotationDegrees: -rotationDegrees,
            opacity: opacity
        )
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
    @Published var selectedPageIDs: Set<UUID> = []
    @Published var mode: WorkspaceMode = .page
    @Published var pairAlignment = PairAlignment()
    @Published var fixedPageID: UUID?
    @Published var statusMessage = "Import a scan or connect a scanner."
    @Published var lastError: String?

    private var alignmentPairKey: [UUID] = []

    var selectedPages: [ScanPage] {
        pages.filter { selectedPageIDs.contains($0.id) }
    }

    var selectedPage: ScanPage? {
        selectedPages.count == 1 ? selectedPages[0] : nil
    }

    var canAlignPair: Bool { selectedPages.count == 2 }

    var alignmentPages: [ScanPage] {
        canAlignPair ? selectedPages : []
    }

    var fixedPage: ScanPage? {
        guard canAlignPair else { return nil }
        if let fixedPageID, let page = alignmentPages.first(where: { $0.id == fixedPageID }) { return page }
        return alignmentPages.first
    }

    var movingPage: ScanPage? {
        guard let fixedPage else { return nil }
        return alignmentPages.first(where: { $0.id != fixedPage.id })
    }

    func setSelection(_ ids: Set<UUID>) {
        let existing = Set(pages.map(\.id))
        selectedPageIDs = ids.intersection(existing)

        if selectedPageIDs.count != 2 {
            mode = .page
            fixedPageID = nil
            alignmentPairKey = []
            if selectedPageIDs.count > 2 {
                statusMessage = "\(selectedPageIDs.count) pages selected. Select exactly two pages to align."
            }
            return
        }

        let key = pages.filter { selectedPageIDs.contains($0.id) }.map(\.id)
        if key != alignmentPairKey {
            alignmentPairKey = key
            fixedPageID = key.first
            resetPairAlignment()
            statusMessage = "Two pages selected. Choose Align Pair to register them."
        } else if fixedPageID == nil || !selectedPageIDs.contains(fixedPageID!) {
            fixedPageID = key.first
        }
    }

    func addFiles(_ urls: [URL]) {
        do {
            var added: [ScanPage] = []
            for url in urls {
                added.append(contentsOf: try ImagePipeline.loadPages(from: url))
            }
            for page in added {
                page.crop = ImagePipeline.suggestCrop(for: page)
                page.cropValidated = false
            }
            pages.append(contentsOf: added)
            if let newest = added.last {
                setSelection([newest.id])
                mode = .page
            }
            statusMessage = added.count == 1 ? "1 page added. Review the suggested crop." : "\(added.count) pages added. Review the suggested crops."
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
        guard !selectedPageIDs.isEmpty else { return }
        pages.removeAll { selectedPageIDs.contains($0.id) }
        setSelection(pages.first.map { [$0.id] } ?? [])
    }

    func validateCropAndAdvance(_ page: ScanPage) {
        page.cropValidated = true
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        if let next = pages[(index + 1)...].first(where: { !$0.cropValidated }) ?? pages[..<index].first(where: { !$0.cropValidated }) {
            setSelection([next.id])
            statusMessage = "Crop validated. Review the next page."
        } else {
            statusMessage = "Crop validated. All pages are reviewed."
        }
    }

    func resetPairAlignment() {
        guard let fixedPage, let movingPage,
              let fixedIndex = pages.firstIndex(where: { $0.id == fixedPage.id }),
              let movingIndex = pages.firstIndex(where: { $0.id == movingPage.id }),
              let fixedImage = ImagePipeline.render(fixedPage, applyCrop: true),
              let movingImage = ImagePipeline.render(movingPage, applyCrop: true) else { return }

        if movingIndex > fixedIndex {
            pairAlignment.reset(offsetX: CGFloat(fixedImage.width) * 0.90)
        } else {
            pairAlignment.reset(offsetX: -CGFloat(movingImage.width) * 0.90)
        }
    }

    func swapAlignmentRoles() {
        guard let oldFixed = fixedPage, let oldMoving = movingPage,
              let fixedImage = ImagePipeline.render(oldFixed, applyCrop: true),
              let movingImage = ImagePipeline.render(oldMoving, applyCrop: true) else { return }

        pairAlignment = pairAlignment.inverted(
            fixedSize: CGSize(width: fixedImage.width, height: fixedImage.height),
            movingSize: CGSize(width: movingImage.width, height: movingImage.height)
        )
        fixedPageID = oldMoving.id
        statusMessage = "Fixed and moving pages swapped. The current alignment was preserved."
    }

    func setFixedPage(_ page: ScanPage) {
        guard canAlignPair, selectedPageIDs.contains(page.id), page.id != fixedPageID else { return }
        swapAlignmentRoles()
    }

    func suggestCurrentPairAlignment() -> PairAlignment? {
        guard let fixedPage, let movingPage,
              let fixedIndex = pages.firstIndex(where: { $0.id == fixedPage.id }),
              let movingIndex = pages.firstIndex(where: { $0.id == movingPage.id }) else { return nil }

        if movingIndex > fixedIndex {
            return ImagePipeline.suggestPairAlignment(fixedPage, movingPage)
        }

        guard let reverse = ImagePipeline.suggestPairAlignment(movingPage, fixedPage) else { return nil }
        return PairAlignment(
            offsetX: -reverse.offsetX,
            offsetY: -reverse.offsetY,
            rotationDegrees: -reverse.rotationDegrees,
            opacity: reverse.opacity
        )
    }

    func exportCurrent() {
        do {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = mode == .align && canAlignPair ? "spread.tiff" : "scan.tiff"
            panel.allowedContentTypes = [.tiff, .png, .jpeg]
            guard panel.runModal() == .OK, let url = panel.url else { return }

            if mode == .align, let fixedPage, let movingPage {
                guard let image = ImagePipeline.renderPair(fixedPage, movingPage, alignment: pairAlignment) else {
                    throw ScanError.renderFailed
                }
                try ImagePipeline.write(image, to: url, properties: fixedPage.sourceProperties)
            } else if let page = selectedPage {
                guard let image = ImagePipeline.render(page, applyCrop: true) else {
                    throw ScanError.renderFailed
                }
                try ImagePipeline.write(image, to: url, properties: page.sourceProperties)
            } else {
                return
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
