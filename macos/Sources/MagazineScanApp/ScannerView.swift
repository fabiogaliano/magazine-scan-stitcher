import AppKit
@preconcurrency import ImageCaptureCore
@preconcurrency import Quartz
import SwiftUI

struct ScannerSheet: View {
    @ObservedObject var service: ScannerService
    let onScan: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scan")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !service.scanners.isEmpty {
                    Picker("Scanner", selection: Binding(
                        get: { service.selectedScannerID ?? service.scanners.first?.magazineScanID ?? "" },
                        set: { service.selectedScannerID = $0 }
                    )) {
                        ForEach(service.scanners, id: \.magazineScanID) { scanner in
                            Text(scanner.name ?? "Scanner").tag(scanner.magazineScanID)
                        }
                    }
                    .frame(maxWidth: 280)
                }
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            if let scanner = service.selectedScanner {
                ScannerDeviceView(scanner: scanner) { url in
                    onScan(url)
                }
                .frame(minWidth: 720, minHeight: 520)
            } else {
                VStack(spacing: 12) {
                    if service.isSearching { ProgressView() }
                    Image(systemName: "scanner")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text(service.isSearching ? "Looking for scanners…" : "No scanner found")
                        .font(.headline)
                    Text("You can still import TIFF, PNG, JPEG, or PDF scans from the toolbar.")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 720, minHeight: 520)
            }
        }
    }
}

struct ScannerDeviceView: NSViewRepresentable {
    let scanner: ICScannerDevice
    let onScan: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeNSView(context: Context) -> IKScannerDeviceView {
        let view = IKScannerDeviceView(frame: .zero)
        view.scannerDevice = scanner
        view.delegate = context.coordinator
        view.mode = .simple
        view.hasDisplayModeSimple = true
        view.hasDisplayModeAdvanced = true
        view.transferMode = .fileBased
        view.displaysDownloadsDirectoryControl = false
        view.displaysPostProcessApplicationControl = false
        view.downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagazineScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: view.downloadsDirectory, withIntermediateDirectories: true)
        view.documentName = "scan"
        view.scanControlLabel = "Scan"
        view.overviewControlLabel = "Preview"
        return view
    }

    func updateNSView(_ nsView: IKScannerDeviceView, context: Context) {
        if nsView.scannerDevice !== scanner { nsView.scannerDevice = scanner }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency IKScannerDeviceViewDelegate {
        let onScan: (URL) -> Void
        init(onScan: @escaping (URL) -> Void) { self.onScan = onScan }

        func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didScanTo url: URL!, error: (any Error)!) {
            guard error == nil, let url else { return }
            onScan(url)
        }
    }
}
