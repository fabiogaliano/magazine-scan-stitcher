import Combine
import Foundation
import ImageCaptureCore

@MainActor
extension ICDevice {
    var magazineScanID: String { persistentIDString ?? uuidString ?? name ?? String(ObjectIdentifier(self).hashValue) }
}

@MainActor
final class ScannerService: NSObject, ObservableObject, ICDeviceBrowserDelegate {
    @Published private(set) var scanners: [ICScannerDevice] = []
    @Published var selectedScannerID: String?
    @Published var isSearching = true

    private let browser = ICDeviceBrowser()

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .scanner
        browser.start()
    }

    deinit { browser.stop() }

    var selectedScanner: ICScannerDevice? {
        if let selectedScannerID,
           let match = scanners.first(where: { $0.magazineScanID == selectedScannerID }) { return match }
        return scanners.first
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        Task { @MainActor in
            if !scanners.contains(where: { $0.magazineScanID == scanner.magazineScanID }) {
                scanners.append(scanner)
                scanners.sort { ($0.name ?? "") < ($1.name ?? "") }
                if selectedScannerID == nil { selectedScannerID = scanner.magazineScanID }
            }
            if !moreComing { isSearching = false }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            scanners.removeAll { $0.magazineScanID == device.magazineScanID }
            if selectedScannerID == device.magazineScanID { selectedScannerID = scanners.first?.magazineScanID }
        }
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        Task { @MainActor in isSearching = false }
    }
}
