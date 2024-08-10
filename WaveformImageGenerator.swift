import AVFoundation
import UIKit

class WaveformImageGenerator {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func waveformImage(size: CGSize, color: UIColor = .blue, backgroundColor: UIColor = .white) -> UIImage? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let assetTrack = asset.tracks(withMediaType: .audio).first
        guard let track = assetTrack else { return nil }

        let assetReader = try? AVAssetReader(asset: asset)

        let outputSettingsDict: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettingsDict)
        assetReader?.add(readerOutput)
        assetReader?.startReading()

        var samples = [Float]()
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(repeating: 0, count: length)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)

                data.withUnsafeBytes { (samplesBuffer: UnsafeRawBufferPointer) in
                    let samplesData = samplesBuffer.bindMemory(to: Int16.self)
                    samples.append(contentsOf: samplesData.map { Float($0) / Float(Int16.max) })
                }
                CMSampleBufferInvalidate(sampleBuffer)
            }
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            ctx.cgContext.setFillColor(backgroundColor.cgColor)
            ctx.cgContext.fill(CGRect(origin: .zero, size: size))

            let path = UIBezierPath()
            let middleY = size.height / 2
            for (index, sample) in samples.enumerated() {
                let xPos = CGFloat(index) / CGFloat(samples.count) * size.width
                path.move(to: CGPoint(x: xPos, y: middleY))
                path.addLine(to: CGPoint(x: xPos, y: middleY - CGFloat(sample) * middleY))
            }
            path.lineWidth = 1
            ctx.cgContext.setLineWidth(1)
            ctx.cgContext.setStrokeColor(color.cgColor)
            ctx.cgContext.addPath(path.cgPath)
            ctx.cgContext.drawPath(using: .stroke)
        }
    }
}
