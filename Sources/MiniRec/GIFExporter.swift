import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

public final class GIFExporter: @unchecked Sendable {
    public struct Config: Sendable {
        public let fps: Int
        public let maxWidth: CGFloat?
        public let loopCount: Int // 0 = infinite loop
        
        public init(fps: Int = 12, maxWidth: CGFloat? = 800, loopCount: Int = 0) {
            self.fps = fps
            self.maxWidth = maxWidth
            self.loopCount = loopCount
        }
    }
    
    public init() {}
    
    public func exportGIF(
        from videoURL: URL,
        to outputURL: URL,
        config: Config = Config(),
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (outputSize: Int64, frameCount: Int, duration: Double) {
        let asset = AVURLAsset(url: videoURL)
        let durationCMTime = try await asset.load(.duration)
        let totalDuration = CMTimeGetSeconds(durationCMTime)
        
        guard totalDuration > 0 else {
            throw NSError(domain: "MiniRec", code: 2, userInfo: [NSLocalizedDescriptionKey: "影片長度無效 (Invalid video duration)"])
        }
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "MiniRec", code: 3, userInfo: [NSLocalizedDescriptionKey: "找不到視訊軌道 (No video track found)"])
        }
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        var targetSize = naturalSize
        if let maxW = config.maxWidth, naturalSize.width > maxW {
            let scale = maxW / naturalSize.width
            targetSize = CGSize(width: maxW, height: naturalSize.height * scale)
        }
        
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = targetSize
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        
        let frameInterval = 1.0 / Double(config.fps)
        var timeValues: [CMTime] = []
        var currentTime = 0.0
        while currentTime < totalDuration {
            timeValues.append(CMTime(seconds: currentTime, preferredTimescale: 600))
            currentTime += frameInterval
        }
        
        guard !timeValues.isEmpty else {
            throw NSError(domain: "MiniRec", code: 4, userInfo: [NSLocalizedDescriptionKey: "未能取樣任何影格 (No frames to extract)"])
        }
        
        try? FileManager.default.removeItem(at: outputURL)
        
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            timeValues.count,
            nil
        ) else {
            throw NSError(domain: "MiniRec", code: 5, userInfo: [NSLocalizedDescriptionKey: "無法建立 GIF 輸出檔案 (Failed to create GIF destination)"])
        }
        
        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: config.loopCount
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameInterval,
                kCGImagePropertyGIFUnclampedDelayTime as String: frameInterval
            ]
        ]
        
        var generatedCount = 0
        for (idx, time) in timeValues.enumerated() {
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
                generatedCount += 1
            } catch {
                // If a single frame fails, continue
                continue
            }
            
            let pct = Double(idx + 1) / Double(timeValues.count)
            onProgress?(pct)
        }
        
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "MiniRec", code: 6, userInfo: [NSLocalizedDescriptionKey: "GIF 檔案封裝失敗 (Failed to finalize GIF)"])
        }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return (size, generatedCount, totalDuration)
    }
}
