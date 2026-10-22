import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import VideoToolbox

public struct RecordingSummary: Sendable {
    public let fileURL: URL
    public let durationSeconds: Double
    public let fileSizeBytes: Int64
    public let averageBitrateKbps: Double
    public let resolution: CGSize
    public let profile: RecordingProfile
    
    public var fileSizeMB: Double {
        Double(fileSizeBytes) / (1024.0 * 1024.0)
    }
}

public enum CaptureTarget: Sendable {
    case display(displayIndex: Int)
    case window(windowID: CGWindowID)
}

public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    
    private let outputURL: URL
    private let profile: RecordingProfile
    private var recordAudio: Bool
    private var recordMicrophone: Bool
    private let showCursor: Bool
    private let target: CaptureTarget
    private let customScale: Double?
    
    private let processingQueue = DispatchQueue(label: "com.minirec.recorder.queue", qos: .userInteractive)
    
    private(set) public var isRecording = false
    private(set) public var isPaused = false
    
    private var sessionStartTime: CMTime = .invalid
    private var lastVideoPTS: CMTime = .invalid
    private var lastWrittenVideoPTS: CMTime = .invalid
    private var lastWrittenAudioPTS: CMTime = .invalid
    private var lastWrittenMicPTS: CMTime = .invalid
    private var pauseStartTime: CMTime = .invalid
    private var totalPauseOffset: CMTime = .zero
    private var needsOffsetAdjustmentOnNextFrame = false
    
    private var frameCount: Int64 = 0
    private var audioSampleCount: Int64 = 0
    private var micSampleCount: Int64 = 0
    private var recordedDuration: Double = 0
    private var targetResolution: CGSize = .zero
    
    public var onStatusUpdate: (@Sendable (Double, Int64) -> Void)?
    
    public init(
        outputURL: URL,
        profile: RecordingProfile = .compact,
        target: CaptureTarget = .display(displayIndex: 0),
        recordAudio: Bool = false,
        recordMicrophone: Bool = false,
        showCursor: Bool = true,
        customScale: Double? = nil
    ) {
        self.outputURL = outputURL
        self.profile = profile
        self.target = target
        self.recordAudio = recordAudio
        self.recordMicrophone = recordMicrophone
        self.showCursor = showCursor
        self.customScale = customScale
        super.init()
    }
    
    public static func checkPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }
    
    public static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }
    
    public static func getAvailableTargets() async throws -> (displays: [SCDisplay], windows: [SCWindow]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return (content.displays, content.windows.filter {
            guard let title = $0.title, !title.isEmpty else { return false }
            return $0.frame.width > 100 && $0.frame.height > 100
        })
    }
    
    public func start() async throws {
        guard Self.checkPermission() else {
            Self.requestPermission()
            throw NSError(domain: "MiniRec", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "尚未取得螢幕錄影權限！請至「系統設定」>「隱私權與安全性」>「螢幕錄影」勾選允許本工具。"
            ])
        }
        
        try? FileManager.default.removeItem(at: outputURL)
        
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        let filter: SCContentFilter
        let sourceWidth: Int
        let sourceHeight: Int
        
        switch target {
        case .display(let index):
            guard index < content.displays.count else {
                throw NSError(domain: "MiniRec", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到指定顯示器 (Display index \(index) not found)"])
            }
            let display = content.displays[index]
            filter = SCContentFilter(display: display, excludingWindows: [])
            sourceWidth = Int(display.width)
            sourceHeight = Int(display.height)
            
        case .window(let winID):
            guard let window = content.windows.first(where: { $0.windowID == winID }) else {
                throw NSError(domain: "MiniRec", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到指定視窗 (Window ID \(winID) not found)"])
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceWidth = Int(window.frame.width)
            sourceHeight = Int(window.frame.height)
        }
        
        // Calculate output dimensions based on profile or custom scale
        let effectiveScale = customScale ?? profile.scaleFactor
        var outWidth = Int(Double(sourceWidth) * effectiveScale)
        var outHeight = Int(Double(sourceHeight) * effectiveScale)
        if outWidth % 2 != 0 { outWidth += 1 }
        if outHeight % 2 != 0 { outHeight += 1 }
        self.targetResolution = CGSize(width: outWidth, height: outHeight)
        
        // Setup AVAssetWriter
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true // Places moov atom at beginning (Fast Start for QuickTime / Web)
        
        var compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: profile.targetBitrate,
            AVVideoMaxKeyFrameIntervalKey: profile.keyFrameInterval,
            AVVideoAllowFrameReorderingKey: true
        ]
        if profile.codec == .hevc {
            compressionProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: profile.codec,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoCompressionPropertiesKey: compressionProps
        ]
        
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        if writer.canAdd(vInput) {
            writer.add(vInput)
            self.videoInput = vInput
        }
        
        // Setup audio if enabled
        if recordAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) {
                writer.add(aInput)
                self.audioInput = aInput
            }
        }
        
        // Setup microphone if enabled
        if recordMicrophone {
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ]
            let mInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            mInput.expectsMediaDataInRealTime = true
            if writer.canAdd(mInput) {
                writer.add(mInput)
                self.micInput = mInput
            }
        }
        
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "MiniRec", code: -1, userInfo: [NSLocalizedDescriptionKey: "無法初始化 AVAssetWriter"])
        }
        self.assetWriter = writer
        
        // Setup ScreenCaptureKit StreamConfiguration
        let config = SCStreamConfiguration()
        config.width = outWidth
        config.height = outHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: profile.fps)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showCursor
        if recordAudio {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
        }
        if #available(macOS 15.0, *) {
            if recordMicrophone {
                config.captureMicrophone = true
            }
        }
        
        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
        
        if recordAudio {
            do {
                try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
            } catch {
                print("⚠ 系統音訊擷取無法啟動，自動切換為純視訊模式: \(error.localizedDescription)")
                self.recordAudio = false
            }
        }
        
        if #available(macOS 15.0, *) {
            if recordMicrophone {
                do {
                    try scStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: processingQueue)
                } catch {
                    print("⚠ 麥克風擷取無法啟動: \(error.localizedDescription)")
                    self.recordMicrophone = false
                }
            }
        }
        
        try await scStream.startCapture()
        self.stream = scStream
        self.isRecording = true
        self.isPaused = false
    }
    
    public func pause() {
        processingQueue.async {
            guard self.isRecording, !self.isPaused else { return }
            self.isPaused = true
            self.pauseStartTime = self.lastVideoPTS
        }
    }
    
    public func resume() {
        processingQueue.async {
            guard self.isRecording, self.isPaused else { return }
            self.isPaused = false
            self.needsOffsetAdjustmentOnNextFrame = true
        }
    }
    
    public func stop() async throws -> RecordingSummary {
        isRecording = false
        isPaused = false
        
        if let s = stream {
            try await s.stopCapture()
            self.stream = nil
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            processingQueue.async {
                guard let writer = self.assetWriter else {
                    continuation.resume(throwing: NSError(domain: "MiniRec", code: -2, userInfo: [NSLocalizedDescriptionKey: "錄影核心尚未建立"]))
                    return
                }
                
                // If audio track was added but no audio samples were ever received,
                // we append a silent audio frame so AVAssetWriter's AAC encoder doesn't fail on finishWriting
                if self.recordAudio, let aInput = self.audioInput, self.audioSampleCount == 0, self.sessionStartTime.isValid {
                    self.appendSilenceAudioSample(to: aInput, at: self.sessionStartTime)
                }
                if self.recordMicrophone, let mInput = self.micInput, self.micSampleCount == 0, self.sessionStartTime.isValid {
                    self.appendSilenceAudioSample(to: mInput, at: self.sessionStartTime)
                }
                
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.micInput?.markAsFinished()
                
                writer.finishWriting {
                    if writer.status == .failed {
                        let err = writer.error ?? NSError(domain: "MiniRec", code: -3, userInfo: [NSLocalizedDescriptionKey: "影片封裝失敗 (AVAssetWriter status == failed)"])
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: self.outputURL.path)[.size] as? Int64) ?? 0
                    let duration = self.recordedDuration
                    let bitrate = duration > 0 ? (Double(fileSize * 8) / duration / 1000.0) : 0
                    
                    continuation.resume(returning: RecordingSummary(
                        fileURL: self.outputURL,
                        durationSeconds: duration,
                        fileSizeBytes: fileSize,
                        averageBitrateKbps: bitrate,
                        resolution: self.targetResolution,
                        profile: self.profile
                    ))
                }
            }
        }
    }
    
    private func appendSilenceAudioSample(to input: AVAssetWriterInput, at time: CMTime) {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc)
        
        let sampleCount = 1024
        let byteCount = sampleCount * 8
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
        
        if let bb = blockBuffer {
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: bb, offsetIntoDestination: 0, dataLength: byteCount)
            var timing = CMSampleTimingInfo(duration: CMTime(value: Int64(sampleCount), timescale: 48000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var sampleBuffer: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: bb, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc, sampleCount: sampleCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
            
            if let sb = sampleBuffer, input.isReadyForMoreMediaData {
                input.append(sb)
            }
        }
    }
    
    // MARK: - SCStreamOutput
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording else { return }
        guard sampleBuffer.isValid else { return }
        
        if isPaused { return }
        
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if needsOffsetAdjustmentOnNextFrame {
            if pauseStartTime.isValid {
                let pauseDelta = CMTimeSubtract(originalPTS, pauseStartTime)
                if CMTimeGetSeconds(pauseDelta) > 0 {
                    totalPauseOffset = CMTimeAdd(totalPauseOffset, pauseDelta)
                }
            }
            needsOffsetAdjustmentOnNextFrame = false
        }
        
        if type == .screen {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let attachments = attachmentsArray.first,
               let statusRawValue = attachments[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRawValue),
               status != .complete {
                return
            }
            
            lastVideoPTS = originalPTS
        }
        
        guard let writer = assetWriter, writer.status == .writing else { return }
        
        // CRITICAL FIX: The session MUST be anchored to the FIRST VIDEO frame!
        if !sessionStartTime.isValid {
            guard type == .screen else { return } // Drop any audio packets arriving before video
            sessionStartTime = originalPTS
            writer.startSession(atSourceTime: originalPTS)
        }
        
        // Calculate adjusted presentation timestamp
        let adjustedPTS = CMTimeSubtract(originalPTS, totalPauseOffset)
        
        if type == .screen {
            guard !lastWrittenVideoPTS.isValid || adjustedPTS > lastWrittenVideoPTS else { return }
            
            var timingInfo = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: adjustedPTS,
                decodeTimeStamp: .invalid
            )
            
            var adjustedBuffer: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleBufferOut: &adjustedBuffer
            )
            
            guard let finalBuffer = adjustedBuffer else { return }
            
            if let vInput = videoInput, vInput.isReadyForMoreMediaData {
                if vInput.append(finalBuffer) {
                    lastWrittenVideoPTS = adjustedPTS
                    frameCount += 1
                    recordedDuration = CMTimeGetSeconds(CMTimeSubtract(adjustedPTS, sessionStartTime))
                    
                    if frameCount % 30 == 0 {
                        let currentSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                        onStatusUpdate?(recordedDuration, currentSize)
                    }
                } else {
                    print("⚠ 視訊影格寫入失敗: status=\(writer.status.rawValue), error=\(String(describing: writer.error))")
                }
            }
        } else if type == .audio {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            guard let aInput = audioInput, aInput.isReadyForMoreMediaData else { return }
            guard adjustedPTS >= sessionStartTime else { return } // Never append audio earlier than session start
            guard !lastWrittenAudioPTS.isValid || adjustedPTS > lastWrittenAudioPTS else { return }
            
            var timingInfo = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: adjustedPTS,
                decodeTimeStamp: .invalid
            )
            
            var adjustedBuffer: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleBufferOut: &adjustedBuffer
            )
            
            let finalBuffer = adjustedBuffer ?? sampleBuffer
            if aInput.append(finalBuffer) {
                lastWrittenAudioPTS = adjustedPTS
                audioSampleCount += 1
            }
        } else {
            if #available(macOS 15.0, *), type == .microphone {
                guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
                guard let mInput = micInput, mInput.isReadyForMoreMediaData else { return }
                guard adjustedPTS >= sessionStartTime else { return }
                guard !lastWrittenMicPTS.isValid || adjustedPTS > lastWrittenMicPTS else { return }
                
                var timingInfo = CMSampleTimingInfo(
                    duration: CMSampleBufferGetDuration(sampleBuffer),
                    presentationTimeStamp: adjustedPTS,
                    decodeTimeStamp: .invalid
                )
                
                var adjustedBuffer: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: sampleBuffer,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timingInfo,
                    sampleBufferOut: &adjustedBuffer
                )
                
                let finalBuffer = adjustedBuffer ?? sampleBuffer
                if mInput.append(finalBuffer) {
                    lastWrittenMicPTS = adjustedPTS
                    micSampleCount += 1
                }
            }
        }
    }
}
