import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var scanners: ScannerService
    @State private var showingScanner = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 330)
            } detail: {
                detail
            }

            Divider()
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(workspace.statusMessage)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.bar)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showingScanner) {
            ScannerSheet(service: scanners) { url in workspace.addFiles([url]) }
        }
        .alert("Magazine Scan", isPresented: Binding(
            get: { workspace.lastError != nil },
            set: { if !$0 { workspace.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { workspace.lastError = nil }
        } message: {
            Text(workspace.lastError ?? "")
        }
    }

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { workspace.selectedPageIDs },
            set: { workspace.setSelection($0) }
        )
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                Section("Scans") {
                    ForEach(workspace.pages) { page in
                        PageRow(
                            page: page,
                            role: workspace.mode == .align && workspace.canAlignPair
                                ? (workspace.fixedPageID == page.id ? "Fixed" : (workspace.selectedPageIDs.contains(page.id) ? "Moving" : nil))
                                : nil
                        )
                        .tag(page.id)
                    }
                }
            }

            if !workspace.pages.isEmpty {
                VStack(spacing: 6) {
                    HStack {
                        Text(selectionSummary)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { workspace.removeSelected() } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(workspace.selectedPageIDs.isEmpty)
                    }

                    if workspace.pages.count >= 2 {
                        HStack(spacing: 5) {
                            Image(systemName: "command")
                            Text("Click two pages to align a pair")
                            Spacer()
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .background(.bar)
            }
        }
    }

    private var selectionSummary: String {
        if workspace.selectedPageIDs.isEmpty {
            return "\(workspace.pages.count) page\(workspace.pages.count == 1 ? "" : "s")"
        }
        return "\(workspace.selectedPageIDs.count) selected"
    }

    @ViewBuilder
    private var detail: some View {
        if workspace.mode == .align, workspace.canAlignPair {
            PairAlignmentView(workspace: workspace)
        } else if let page = workspace.selectedPage {
            PageReviewView(page: page, workspace: workspace)
        } else if workspace.canAlignPair {
            PairReadyView(workspace: workspace)
        } else if workspace.selectedPageIDs.count > 2 {
            SelectionGuideView(
                icon: "rectangle.stack.badge.person.crop",
                title: "Too many pages selected",
                message: "Select exactly two pages in the sidebar to align a spread."
            )
        } else {
            SelectionGuideView(
                icon: "scanner",
                title: workspace.pages.isEmpty ? "Ready to scan" : "Select a page",
                message: workspace.pages.isEmpty
                    ? "Scan directly from a connected device or import an existing scan."
                    : "Select one page to review it, or Command-click two pages to align them."
            ) {
                if workspace.pages.isEmpty {
                    Button("Scan…") { showingScanner = true }
                        .buttonStyle(.borderedProminent)
                    Button("Import…") { workspace.importFiles() }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showingScanner = true } label: { Label("Scan", systemImage: "scanner") }
            Button { workspace.importFiles() } label: { Label("Import", systemImage: "square.and.arrow.down") }
        }
        ToolbarItem(placement: .principal) {
            if workspace.canAlignPair {
                Picker("Mode", selection: $workspace.mode) {
                    ForEach(WorkspaceMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { workspace.exportCurrent() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled((workspace.mode == .page && workspace.selectedPage == nil) || (workspace.mode == .align && !workspace.canAlignPair))
        }
    }
}

struct SelectionGuideView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    init(icon: String, title: String, message: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack { actions() }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension SelectionGuideView where Actions == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

struct PairReadyView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 22) {
                ForEach(workspace.alignmentPages) { page in
                    VStack(spacing: 8) {
                        if let image = ImagePipeline.previewImage(page) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 170, height: 210)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Text(page.title)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 190)
                    }
                }
            }
            Text("Two pages selected")
                .font(.title2.weight(.semibold))
            Text("Start alignment to choose which page stays fixed and position the other over it.")
                .foregroundStyle(.secondary)
            Button("Align Selected Pair") {
                workspace.mode = .align
                workspace.statusMessage = "Align the Moving page over the Fixed page. Swap them at any time."
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PageRow: View {
    @ObservedObject var page: ScanPage
    let role: String?

    var body: some View {
        HStack(spacing: 10) {
            if let image = ImagePipeline.previewImage(page) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(page.sourcePageIndex == 0 ? page.sourceURL.deletingPathExtension().lastPathComponent : "Page \(page.sourcePageIndex + 1)")
                        .lineLimit(1)
                    if let role {
                        Text(role)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: page.cropValidated ? "checkmark.circle.fill" : "crop")
                    Text(page.cropValidated ? "Crop checked" : "Review crop")
                }
                .font(.caption)
                .foregroundStyle(page.cropValidated ? .green : .secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct PageReviewView: View {
    @ObservedObject var page: ScanPage
    @ObservedObject var workspace: WorkspaceModel
    @State private var showGrid = false

    private var hasAnotherUnreviewedPage: Bool {
        workspace.pages.contains { $0.id != page.id && !$0.cropValidated }
    }

    var body: some View {
        VStack(spacing: 0) {
            CropCanvas(page: page, showGrid: showGrid)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()
            HStack(spacing: 14) {
                Button { page.rotateLeft() } label: { Label("Left", systemImage: "rotate.left") }
                Button { page.rotateRight() } label: { Label("Right", systemImage: "rotate.right") }
                Button { page.rotateRight(); page.rotateRight() } label: { Text("180°") }

                Divider().frame(height: 24)

                Button("Auto Crop") {
                    page.crop = ImagePipeline.suggestCrop(for: page)
                    page.cropValidated = false
                    workspace.statusMessage = "Crop suggested. Check the edges, then validate it."
                }
                Button("Reset Crop") {
                    page.crop = .full
                    page.cropValidated = false
                }

                Divider().frame(height: 24)

                Toggle("Grid", isOn: $showGrid)
                    .toggleStyle(.button)
                    .help("Show thirds guides while cropping and deskewing")

                Text("Deskew")
                    .foregroundStyle(.secondary)
                Slider(value: $page.fineRotationDegrees, in: -3...3, step: 0.05)
                    .frame(width: 160)
                Text(String(format: "%+.2f°", page.fineRotationDegrees))
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)

                Spacer()

                Button(page.cropValidated ? "Crop Validated" : (hasAnotherUnreviewedPage ? "Use Crop & Next" : "Use Crop")) {
                    workspace.validateCropAndAdvance(page)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.bar)
        }
    }
}

struct CropCanvas: View {
    @ObservedObject var page: ScanPage
    let showGrid: Bool
    @State private var cropDragStart: UnitCrop?

    var body: some View {
        GeometryReader { geo in
            if let image = ImagePipeline.previewImage(page) {
                let imageSize = image.size
                let fitted = aspectFit(imageSize, in: geo.size, padding: 28)
                ZStack(alignment: .topLeading) {
                    Color.clear
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .shadow(radius: 8, y: 3)

                    cropOverlay(in: fitted)
                }
            }
        }
    }

    @ViewBuilder
    private func cropOverlay(in fitted: CGRect) -> some View {
        let r = CGRect(
            x: fitted.minX + page.crop.x * fitted.width,
            y: fitted.minY + page.crop.y * fitted.height,
            width: page.crop.width * fitted.width,
            height: page.crop.height * fitted.height
        )

        Path { p in
            p.addRect(fitted)
            p.addRect(r)
        }
        .fill(.black.opacity(0.36), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)

        if showGrid {
            Path { p in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    let x = r.minX + r.width * fraction
                    p.move(to: CGPoint(x: x, y: r.minY))
                    p.addLine(to: CGPoint(x: x, y: r.maxY))
                    let y = r.minY + r.height * fraction
                    p.move(to: CGPoint(x: r.minX, y: y))
                    p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.60), lineWidth: 0.8)
            .allowsHitTesting(false)
        }

        Rectangle()
            .stroke(page.cropValidated ? Color.green : Color.accentColor, lineWidth: 2)
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .contentShape(Rectangle())
            .gesture(moveGesture(fitted: fitted))

        handle(.topLeft, at: CGPoint(x: r.minX, y: r.minY), fitted: fitted)
        handle(.topRight, at: CGPoint(x: r.maxX, y: r.minY), fitted: fitted)
        handle(.bottomLeft, at: CGPoint(x: r.minX, y: r.maxY), fitted: fitted)
        handle(.bottomRight, at: CGPoint(x: r.maxX, y: r.maxY), fitted: fitted)
    }

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private func handle(_ corner: Corner, at point: CGPoint, fitted: CGRect) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 13, height: 13)
            .position(point)
            .gesture(resizeGesture(corner, fitted: fitted))
    }

    private func moveGesture(fitted: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if cropDragStart == nil { cropDragStart = page.crop }
                guard var c = cropDragStart else { return }
                c.x += value.translation.width / fitted.width
                c.y += value.translation.height / fitted.height
                c.x = min(max(c.x, 0), 1 - c.width)
                c.y = min(max(c.y, 0), 1 - c.height)
                page.crop = c
                page.cropValidated = false
            }
            .onEnded { _ in cropDragStart = nil }
    }

    private func resizeGesture(_ corner: Corner, fitted: CGRect) -> some Gesture {
        DragGesture().onChanged { value in
            let nx = min(max((value.location.x - fitted.minX) / fitted.width, 0), 1)
            let ny = min(max((value.location.y - fitted.minY) / fitted.height, 0), 1)
            var c = page.crop
            let maxX = c.x + c.width
            let maxY = c.y + c.height
            switch corner {
            case .topLeft:
                c.x = min(nx, maxX - 0.02); c.y = min(ny, maxY - 0.02)
                c.width = maxX - c.x; c.height = maxY - c.y
            case .topRight:
                c.y = min(ny, maxY - 0.02); c.width = max(0.02, nx - c.x); c.height = maxY - c.y
            case .bottomLeft:
                c.x = min(nx, maxX - 0.02); c.width = maxX - c.x; c.height = max(0.02, ny - c.y)
            case .bottomRight:
                c.width = max(0.02, nx - c.x); c.height = max(0.02, ny - c.y)
            }
            c.clamp()
            page.crop = c
            page.cropValidated = false
        }
    }
}

struct PairAlignmentView: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var dragStartX: CGFloat?
    @State private var dragStartY: CGFloat?
    @State private var differenceMode = false

    private var fixed: ScanPage { workspace.fixedPage! }
    private var moving: ScanPage { workspace.movingPage! }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                roleChip("Fixed", page: fixed, emphasized: true)
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                roleChip("Moving", page: moving, emphasized: false)
                Button("Swap") { workspace.swapAlignmentRoles() }
                    .help("Keep the other selected page fixed without losing the current alignment")
                Spacer()
                Text("Drag Moving over Fixed, then verify shared details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
            Divider()

            GeometryReader { geo in
                if let a = ImagePipeline.editedImage(fixed), let b = ImagePipeline.editedImage(moving) {
                    let unionWidth = max(a.size.width, workspace.pairAlignment.offsetX + b.size.width) - min(0, workspace.pairAlignment.offsetX)
                    let unionHeight = max(a.size.height, workspace.pairAlignment.offsetY + b.size.height) - min(0, workspace.pairAlignment.offsetY)
                    let scale = min((geo.size.width - 40) / max(unionWidth, 1), (geo.size.height - 40) / max(unionHeight, 1))
                    let origin = CGPoint(
                        x: 20 - min(0, workspace.pairAlignment.offsetX) * scale,
                        y: 20 - min(0, workspace.pairAlignment.offsetY) * scale
                    )

                    ZStack(alignment: .topLeading) {
                        Color(nsColor: .windowBackgroundColor)
                        Image(nsImage: a)
                            .resizable()
                            .frame(width: a.size.width * scale, height: a.size.height * scale)
                            .position(x: origin.x + a.size.width * scale / 2, y: origin.y + a.size.height * scale / 2)

                        Image(nsImage: b)
                            .resizable()
                            .frame(width: b.size.width * scale, height: b.size.height * scale)
                            .rotationEffect(.degrees(workspace.pairAlignment.rotationDegrees))
                            .opacity(differenceMode ? 1 : workspace.pairAlignment.opacity)
                            .blendMode(differenceMode ? .difference : .normal)
                            .position(
                                x: origin.x + (workspace.pairAlignment.offsetX + b.size.width / 2) * scale,
                                y: origin.y + (workspace.pairAlignment.offsetY + b.size.height / 2) * scale
                            )
                            .gesture(DragGesture()
                                .onChanged { value in
                                    if dragStartX == nil {
                                        dragStartX = workspace.pairAlignment.offsetX
                                        dragStartY = workspace.pairAlignment.offsetY
                                    }
                                    workspace.pairAlignment.offsetX = (dragStartX ?? 0) + value.translation.width / scale
                                    workspace.pairAlignment.offsetY = (dragStartY ?? 0) + value.translation.height / scale
                                }
                                .onEnded { _ in dragStartX = nil; dragStartY = nil })
                    }
                }
            }

            Divider()
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button("Auto Align") {
                        if let suggestion = workspace.suggestCurrentPairAlignment() {
                            workspace.pairAlignment = suggestion
                            workspace.statusMessage = "Alignment suggested. Verify it with Overlay, Difference, or Flicker before exporting."
                        } else {
                            workspace.statusMessage = "Could not find a useful edge-overlap suggestion. Align manually."
                        }
                    }
                    .help("Suggest a translation using only the expected page-edge overlap")

                    Button("Reset") { workspace.resetPairAlignment() }

                    Spacer()
                    Toggle("Difference", isOn: $differenceMode)
                        .toggleStyle(.button)
                        .help("Difference view makes misaligned shared details stand out")
                    Text("Overlay").foregroundStyle(.secondary)
                    Slider(value: $workspace.pairAlignment.opacity, in: 0...1)
                        .frame(width: 150)
                        .disabled(differenceMode)
                    Button("Flicker") {
                        differenceMode = false
                        workspace.pairAlignment.opacity = workspace.pairAlignment.opacity < 0.9 ? 1 : 0
                    }
                }

                HStack(spacing: 10) {
                    Text("Position").foregroundStyle(.secondary)
                    Text("X")
                    TextField("X", text: numberBinding(
                        get: { workspace.pairAlignment.offsetX },
                        set: { workspace.pairAlignment.offsetX = $0 }
                    ))
                    .frame(width: 70)
                    Text("Y")
                    TextField("Y", text: numberBinding(
                        get: { workspace.pairAlignment.offsetY },
                        set: { workspace.pairAlignment.offsetY = $0 }
                    ))
                    .frame(width: 70)
                    nudgeButtons

                    Spacer()
                    Text("Rotate Moving").foregroundStyle(.secondary)
                    Slider(value: $workspace.pairAlignment.rotationDegrees, in: -3...3, step: 0.02)
                        .frame(width: 190)
                    Text(String(format: "%+.2f°", workspace.pairAlignment.rotationDegrees))
                        .monospacedDigit().frame(width: 56)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }

    private func roleChip(_ role: String, page: ScanPage, emphasized: Bool) -> some View {
        HStack(spacing: 6) {
            Text(role)
                .font(.caption.weight(.semibold))
                .foregroundStyle(emphasized ? .primary : .secondary)
            Text(page.title)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(emphasized ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func numberBinding(get: @escaping () -> CGFloat, set: @escaping (CGFloat) -> Void) -> Binding<String> {
        Binding(
            get: { String(format: "%.1f", get()) },
            set: { text in if let value = Double(text) { set(CGFloat(value)) } }
        )
    }

    private var nudgeButtons: some View {
        HStack(spacing: 3) {
            Button { workspace.pairAlignment.offsetX -= 1 } label: { Image(systemName: "arrow.left") }
            VStack(spacing: 3) {
                Button { workspace.pairAlignment.offsetY -= 1 } label: { Image(systemName: "arrow.up") }
                Button { workspace.pairAlignment.offsetY += 1 } label: { Image(systemName: "arrow.down") }
            }
            Button { workspace.pairAlignment.offsetX += 1 } label: { Image(systemName: "arrow.right") }
        }
        .buttonStyle(.borderless)
        .help("Nudge the Moving page by one pixel")
    }
}

private func aspectFit(_ imageSize: CGSize, in container: CGSize, padding: CGFloat = 0) -> CGRect {
    let available = CGSize(width: max(1, container.width - padding * 2), height: max(1, container.height - padding * 2))
    let scale = min(available.width / imageSize.width, available.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
}
