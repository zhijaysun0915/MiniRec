import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import VideoToolbox

public struct BenchmarkResult: Sendable {
    public let profileName: String
    public let codec: String
    public let targetBitrate: String
    public let fps: Int32
    public let fileSizeMB: Double
    public let actualBitrateKbps: Double
    public let encodeDuration: Double
    public let fpsAchieved: Double
    public let realtimeMultiplier: Double
    public let savingsPercent: Double
    public let tenMinuteProjectionMB: Double
}

public final class BenchmarkSuite: @unchecked Sendable {
    public init() {}
    
    private func drawScreenFrame(buffer: CVPixelBuffer, frameIndex: Int, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        
        // Background - Dark theme IDE / terminal
        context.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        // Window Titlebar
        context.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1.0))
        context.fill(CGRect(x: 0, y: height - 38, width: width, height: 38))
        
        // Traffic lights
        context.setFillColor(CGColor(red: 0.95, green: 0.36, blue: 0.36, alpha: 1.0))
        context.fillEllipse(in: CGRect(x: 18, y: height - 26, width: 12, height: 12))
        context.setFillColor(CGColor(red: 0.95, green: 0.74, blue: 0.28, alpha: 1.0))
        context.fillEllipse(in: CGRect(x: 38, y: height - 26, width: 12, height: 12))
        context.setFillColor(CGColor(red: 0.32, green: 0.85, blue: 0.44, alpha: 1.0))
        context.fillEllipse(in: CGRect(x: 58, y: height - 26, width: 12, height: 12))
        
        // Sidebar
        context.setFillColor(CGColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: 220, height: height - 38))
        
        // File tree items
        for i in 0..<12 {
            let y = height - 70 - (i * 28)
            context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 0.7))
            context.fill(CGRect(x: 25, y: y, width: 140, height: 12))
        }
        
        // Code editor lines
        for i in 0..<32 {
            let y = height - 60 - (i * 24)
            if y < 40 { break }
            
            // Line numbers
            context.setFillColor(CGColor(red: 0.35, green: 0.35, blue: 0.40, alpha: 1.0))
            context.fill(CGRect(x: 235, y: y, width: 20, height: 12))
            
            // Syntax highlighted code blocks
            let lineLen = (180 + ((i * 47 + (frameIndex / 3)) % 520))
            let r = Double((i * 17) % 10) / 10.0 * 0.4 + 0.5
            let g = Double((i * 31) % 10) / 10.0 * 0.4 + 0.5
            let b = Double((i * 53) % 10) / 10.0 * 0.4 + 0.5
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1.0))
            context.fill(CGRect(x: 275, y: y, width: lineLen, height: 14))
        }
        
        // Animated mouse cursor
        let mouseX = 260 + (frameIndex * 7) % (width - 400)
        let mouseY = (height / 2) + Int(sin(Double(frameIndex) * 0.12) * 200)
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95))
        context.fill(CGRect(x: mouseX, y: mouseY, width: 14, height: 18))
    }
    
    public func runBenchmark(
        width: Int = 1920,
        height: Int = 1080,
        durationSeconds: Int = 8,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) -> [BenchmarkResult] {
        struct Config {
            let label: String
            let codec: AVVideoCodecType
            let codecName: String
            let targetBitrate: Int
            let fps: Int32
            let keyframeInterval: Int
        }
        
        let configs: [Config] = [
            Config(label: "macOS 內建 QuickTime 預設 (H.264 高位元率)", codec: .h264, codecName: "H.264", targetBitrate: 22_000_000, fps: 60, keyframeInterval: 60),
            Config(label: "MiniRec Pro (高幀率流暢 HEVC 60fps)", codec: .hevc, codecName: "HEVC (H.265)", targetBitrate: 7_000_000, fps: 60, keyframeInterval: 120),
            Config(label: "MiniRec Balanced (平衡高畫質 HEVC 30fps)", codec: .hevc, codecName: "HEVC (H.265)", targetBitrate: 3_500_000, fps: 30, keyframeInterval: 90),
            Config(label: "MiniRec Compact (極小體積 HEVC - 預設)", codec: .hevc, codecName: "HEVC (H.265)", targetBitrate: 1_500_000, fps: 30, keyframeInterval: 90),
            Config(label: "MiniRec Ultra (極限壓縮 HEVC 24fps)", codec: .hevc, codecName: "HEVC (H.265)", targetBitrate: 600_000, fps: 24, keyframeInterval: 96),
            Config(label: "MiniRec Web (跨平台相容 H.264 30fps)", codec: .h264, codecName: "H.264", targetBitrate: 2_200_000, fps: 30, keyframeInterval: 60)
        ]
        
        var results: [BenchmarkResult] = []
        var baselineSize: Int64 = 0
        let tempDir = NSTemporaryDirectory()
        
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        
        for (index, cfg) in configs.enumerated() {
            onProgress?("正在測試 [\(index + 1)/\(configs.count)]: \(cfg.label)...")
            let outPath = "\(tempDir)minirec_bench_\(index).mp4"
            let outUrl = URL(fileURLWithPath: outPath)
            try? FileManager.default.removeItem(at: outUrl)
            
            guard let writer = try? AVAssetWriter(outputURL: outUrl, fileType: .mp4) else { continue }
            
            var compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: cfg.targetBitrate,
                AVVideoMaxKeyFrameIntervalKey: cfg.keyframeInterval,
                AVVideoAllowFrameReorderingKey: true
            ]
            if cfg.codec == .hevc {
                compressionProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
            }
            
            let outputSettings: [String: Any] = [
                AVVideoCodecKey: cfg.codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compressionProps
            ]
            
            let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: writerInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )
            
            writer.add(writerInput)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            
            let totalFrames = Int(cfg.fps) * durationSeconds
            let startTime = Date()
            
            for frame in 0..<totalFrames {
                while !writerInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb)
                guard let buffer = pb else { continue }
                
                drawScreenFrame(buffer: buffer, frameIndex: frame, width: width, height: height)
                let pts = CMTime(value: Int64(frame), timescale: cfg.fps)
                adaptor.append(buffer, withPresentationTime: pts)
            }
            
            writerInput.markAsFinished()
            let sem = DispatchSemaphore(value: 0)
            writer.finishWriting { sem.signal() }
            sem.wait()
            
            let encodeDuration = Date().timeIntervalSince(startTime)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: outPath)[.size] as? Int64) ?? 0
            
            if index == 0 {
                baselineSize = fileSize
            }
            
            let fileSizeMB = Double(fileSize) / (1024.0 * 1024.0)
            let actualBitrateKbps = Double(fileSize * 8) / Double(durationSeconds) / 1000.0
            let fpsAchieved = Double(totalFrames) / encodeDuration
            let realtimeMultiplier = fpsAchieved / Double(cfg.fps)
            let savings = baselineSize > 0 ? (1.0 - Double(fileSize) / Double(baselineSize)) * 100.0 : 0.0
            let tenMinMB = fileSizeMB * (600.0 / Double(durationSeconds))
            
            results.append(BenchmarkResult(
                profileName: cfg.label,
                codec: cfg.codecName,
                targetBitrate: "\(cfg.targetBitrate / 1_000_000)M",
                fps: cfg.fps,
                fileSizeMB: fileSizeMB,
                actualBitrateKbps: actualBitrateKbps,
                encodeDuration: encodeDuration,
                fpsAchieved: fpsAchieved,
                realtimeMultiplier: realtimeMultiplier,
                savingsPercent: savings,
                tenMinuteProjectionMB: tenMinMB
            ))
            
            try? FileManager.default.removeItem(at: outUrl)
        }
        
        return results
    }
}
