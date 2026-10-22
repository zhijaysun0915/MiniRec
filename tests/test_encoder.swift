import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

func drawScreenFrame(buffer: CVPixelBuffer, frameIndex: Int, width: Int, height: Int) {
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
    
    // Background (Editor dark theme)
    context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    
    // Window header bar
    context.setFillColor(CGColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0))
    context.fill(CGRect(x: 0, y: height - 40, width: width, height: 40))
    
    // Window buttons
    context.setFillColor(CGColor(red: 0.95, green: 0.35, blue: 0.35, alpha: 1.0))
    context.fillEllipse(in: CGRect(x: 20, y: height - 25, width: 12, height: 12))
    context.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.25, alpha: 1.0))
    context.fillEllipse(in: CGRect(x: 40, y: height - 25, width: 12, height: 12))
    context.setFillColor(CGColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1.0))
    context.fillEllipse(in: CGRect(x: 60, y: height - 25, width: 12, height: 12))
    
    // Simulated lines of code/text
    for i in 0..<35 {
        let y = height - 80 - (i * 24)
        if y < 40 { break }
        
        let lineWidth = (150 + ((i * 37 + (frameIndex / 4)) % 500))
        let r = Double((i * 13) % 10) / 10.0 * 0.5 + 0.4
        let g = Double((i * 29) % 10) / 10.0 * 0.5 + 0.4
        let b = Double((i * 47) % 10) / 10.0 * 0.5 + 0.4
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1.0))
        context.fill(CGRect(x: 50, y: y, width: lineWidth, height: 14))
    }
    
    // Simulated moving mouse cursor
    let mouseX = (frameIndex * 8) % (width - 100) + 50
    let mouseY = height / 2 + Int(sin(Double(frameIndex) * 0.1) * 150)
    context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    context.fill(CGRect(x: mouseX, y: mouseY, width: 16, height: 20))
}

struct EncodeConfig {
    let name: String
    let codec: AVVideoCodecType
    let bitrate: Int?
    let fps: Int32
    let maxKeyFrameInterval: Int
}

func encodeVideo(outputPath: String, config: EncodeConfig, width: Int, height: Int, durationSeconds: Int) -> (fileSize: Int, encodeDuration: Double) {
    let fileUrl = URL(fileURLWithPath: outputPath)
    try? FileManager.default.removeItem(at: fileUrl)
    
    guard let writer = try? AVAssetWriter(outputURL: fileUrl, fileType: .mp4) else {
        fatalError("Failed to init AVAssetWriter")
    }
    
    var compressionProperties: [String: Any] = [
        AVVideoMaxKeyFrameIntervalKey: config.maxKeyFrameInterval,
        AVVideoAllowFrameReorderingKey: true
    ]
    if let bitrate = config.bitrate {
        compressionProperties[AVVideoAverageBitRateKey] = bitrate
    }
    if config.codec == .hevc {
        compressionProperties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
    }
    
    let outputSettings: [String: Any] = [
        AVVideoCodecKey: config.codec,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: compressionProperties
    ]
    
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    let sourcePixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: writerInput,
        sourcePixelBufferAttributes: sourcePixelBufferAttributes
    )
    
    writer.add(writerInput)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    
    let totalFrames = Int(config.fps) * durationSeconds
    let startTime = Date()
    
    let attrs = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ] as CFDictionary
    
    for frame in 0..<totalFrames {
        while !writerInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }
        
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer)
        }
        
        guard let pixelBuffer = buffer else { continue }
        drawScreenFrame(buffer: pixelBuffer, frameIndex: frame, width: width, height: height)
        let presentationTime = CMTime(value: Int64(frame), timescale: config.fps)
        adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
    }
    
    writerInput.markAsFinished()
    
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
        semaphore.signal()
    }
    semaphore.wait()
    
    let encodeDuration = Date().timeIntervalSince(startTime)
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
    return (fileSize, encodeDuration)
}

print("==========================================================================================")
print("  Screen Recorder Performance & Compression Benchmark (Apple VideoToolbox vs QuickTime)  ")
print("==========================================================================================")
let width = 1920
let height = 1080
let duration = 10 // 10 seconds of simulated dynamic screen recording

let configs: [EncodeConfig] = [
    EncodeConfig(name: "macOS Built-in QuickTime Default (H.264 ~20Mbps, 60fps)", codec: .h264, bitrate: 20_000_000, fps: 60, maxKeyFrameInterval: 60),
    EncodeConfig(name: "MiniRec Pro (HEVC Hardware, 60fps, 4.0Mbps)", codec: .hevc, bitrate: 4_000_000, fps: 60, maxKeyFrameInterval: 120),
    EncodeConfig(name: "MiniRec Balanced (HEVC Hardware, 30fps, 1.8Mbps)", codec: .hevc, bitrate: 1_800_000, fps: 30, maxKeyFrameInterval: 90),
    EncodeConfig(name: "MiniRec Compact (HEVC Hardware, 30fps, 900kbps)", codec: .hevc, bitrate: 900_000, fps: 30, maxKeyFrameInterval: 90),
    EncodeConfig(name: "MiniRec Ultra-Small (HEVC Hardware, 24fps, 500kbps)", codec: .hevc, bitrate: 500_000, fps: 24, maxKeyFrameInterval: 120)
]

func padRight(_ str: String, _ len: Int) -> String {
    if str.count >= len { return str }
    return str + String(repeating: " ", count: len - str.count)
}

func padLeft(_ str: String, _ len: Int) -> String {
    if str.count >= len { return str }
    return String(repeating: " ", count: len - str.count) + str
}

print("\(padRight("Profile", 55)) | \(padLeft("File Size", 10)) | \(padLeft("Bitrate", 10)) | \(padLeft("Encode Speed", 18)) | \(padLeft("Savings", 10))")
print(String(repeating: "-", count: 115))

var baselineSize = 0

for (index, cfg) in configs.enumerated() {
    let outPath = "/tmp/benchmark_\(index).mp4"
    let result = encodeVideo(outputPath: outPath, config: cfg, width: width, height: height, durationSeconds: duration)
    
    if index == 0 {
        baselineSize = result.fileSize
    }
    
    let sizeMB = Double(result.fileSize) / (1024.0 * 1024.0)
    let actualBitrateKbps = Double(result.fileSize * 8) / Double(duration) / 1000.0
    let totalFrames = cfg.fps * Int32(duration)
    let fpsAchieved = Double(totalFrames) / result.encodeDuration
    let realtimeMultiplier = fpsAchieved / Double(cfg.fps)
    let savings = baselineSize > 0 ? (1.0 - Double(result.fileSize) / Double(baselineSize)) * 100.0 : 0.0
    
    let speedStr = String(format: "%.1f fps (%.1fx RT)", fpsAchieved, realtimeMultiplier)
    let sizeStr = String(format: "%.2f MB", sizeMB)
    let bitrateStr = String(format: "%.0f kbps", actualBitrateKbps)
    let savingsStr = String(format: "%.1f%%", savings)
    
    print("\(padRight(cfg.name, 55)) | \(padLeft(sizeStr, 10)) | \(padLeft(bitrateStr, 10)) | \(padLeft(speedStr, 18)) | \(padLeft(savingsStr, 10))")
}
print("==========================================================================================\n")
