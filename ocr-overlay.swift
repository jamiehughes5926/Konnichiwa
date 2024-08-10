import UIKit
import VisionKit

class ViewController: UIViewController, DataScannerViewControllerDelegate {

    var dataScannerViewController: DataScannerViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Check if data scanning is supported and available
        guard DataScannerViewController.isSupported && DataScannerViewController.isAvailable else {
            print("Data scanning is not supported or available on this device.")
            return
        }
        
        // Create the data scanner view controller
        let recognizedDataTypes: Set<DataScannerViewController.RecognizedDataType> = [.text()]
        dataScannerViewController = DataScannerViewController(
            recognizedDataTypes: recognizedDataTypes,
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        
        dataScannerViewController?.delegate = self
        addChild(dataScannerViewController!)
        view.addSubview(dataScannerViewController!.view)
        dataScannerViewController!.didMove(toParent: self)
        
        // Start scanning
        try? dataScannerViewController?.startScanning()
    }

    // MARK: - DataScannerViewControllerDelegate methods

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in items {
            highlightItem(item)
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didUpdate items: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in items {
            highlightItem(item)
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didRemove items: [RecognizedItem], allItems: [RecognizedItem]) {
        // Remove highlights if needed
    }
    
    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: Error) {
        print("Data scanner became unavailable: \(error.localizedDescription)")
    }

    // Highlight recognized items
    private func highlightItem(_ item: RecognizedItem) {
        switch item {
        case .text(let text):
            // Highlight the text
            let highlightView = UIView(frame: text.bounds)
            highlightView.backgroundColor = UIColor.yellow.withAlphaComponent(0.3)
            dataScannerViewController?.overlayContainerView.addSubview(highlightView)
        default:
            break
        }
    }
}
