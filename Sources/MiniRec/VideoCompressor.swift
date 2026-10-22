import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

public final class VideoCompressor: @unchecked Sendable {
    public struct CompressionProgress {
        public let progress: Double // 0.0 to 1.0
        public let currentBytes: Int64
        public let elapsedTime: TimeInterval
    }
    
    public init() {}
    
    public func compress(
        inputURL: URL,
        outputURL: URL,
        profile: RecordingProfile = .compact,
        progressHandler: (@Sendable (CompressionProgress) -> Void)? = nil
    ) async throws -> (inputSize: Int64, outputSize: Int64, duration: Double, savings: Double) {
        let inputAttributes = try FileManager.default.attributesOfItem(atPath: inputURL.path)
        let inputSize = (inputAttributes[.size] as? Int64) ?? 0
        
        try? FileManager.default.removeItem(at: outputURL)
        
        let asset = AVURLAsset(url: inputURL)
        let durationCMTime = try await asset.load(.duration)
        let totalDurationSeconds = CMTimeGetSeconds(durationCMTime)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "MiniRec", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到視訊軌道 (No video track found)"])
        }
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        
        // Calculate output dimensions
        var targetWidth = Int(naturalSize.width * profile.scaleFactor)
        var targetHeight = Int(naturalSize.height * profile.scaleFactor)
        // Ensure even dimensions
        if targetWidth % 2 != 0 { targetWidth += 1 }
        if targetHeight % 2 != 0 { targetHeight += 1 }
        
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        // Video reader output
        let readerVideoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerVideoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerVideoSettings)
        readerVideoOutput.alwaysCopiesSampleData = false
        if reader.canAdd(readerVideoOutput) {
            reader.add(readerVideoOutput)
        }
        
        // Video writer input
        var compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: profile.targetBitrate,
            AVVideoMaxKeyFrameIntervalKey: profile.keyFrameInterval,
            AVVideoAllowFrameReorderingKey: true
        ]
        if profile.codec == .hevc {
            compressionProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        
        let writerVideoSettings: [String: Any] = [
            AVVideoCodecKey: profile.codec,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: compressionProps
        ]
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerVideoSettings)
        writerVideoInput.expectsMediaDataInRealTime = false
        writerVideoInput.transform = preferredTransform
        if writer.canAdd(writerVideoInput) {
            writer.add(writerVideoInput)
        }
        
        // Audio processing if present
        var readerAudioOutput: AVAssetReaderTrackOutput?
        var writerAudioInput: AVAssetWriterInput?
        
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let readerAudioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM
            ]
            let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerAudioSettings)
            if reader.canAdd(audioOut) {
                reader.add(audioOut)
                readerAudioOutput = audioOut
                
                let writerAudioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128000
                ]
                let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: writerAudioSettings)
                audioIn.expectsMediaDataInRealTime = false
                if writer.canAdd(audioIn) {
                    writer.add(audioIn)
                    writerAudioInput = audioIn
                }
            }
        }
        
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        let startTime = Date()
        let videoQueue = DispatchQueue(label: "com.minirec.compress.video")
        let audioQueue = DispatchQueue(label: "com.minirec.compress.audio")
        let group = DispatchGroup()
        
        // Transcode video
        group.enter()
        writerVideoInput.requestMediaDataWhenReady(on: videoQueue) {
            while writerVideoInput.isReadyForMoreMediaData {
                if let sampleBuffer = readerVideoOutput.copyNextSampleBuffer() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let currentSec = CMTimeGetSeconds(pts)
                    if totalDurationSeconds > 0 {
                        let pct = min(1.0, max(0.0, currentSec / totalDurationSeconds))
                        progressHandler?(CompressionProgress(
                            progress: pct,
                            currentBytes: 0,
                            elapsedTime: Date().timeIntervalSince(startTime)
                        ))
                    }
                    writerVideoInput.append(sampleBuffer)
                } else {
                    writerVideoInput.markAsFinished()
                    group.leave()
                    break
                }
            }
        }
        
        // Transcode audio
        if let audioOut = readerAudioOutput, let audioIn = writerAudioInput {
            group.enter()
            audioIn.requestMediaDataWhenReady(on: audioQueue) {
                while audioIn.isReadyForMoreMediaData {
                    if let sampleBuffer = audioOut.copyNextSampleBuffer() {
                        audioIn.append(sampleBuffer)
                    } else {
                        audioIn.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }
        }
        
        // Await completion
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) {
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }
        
        let outAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let outputSize = (outAttributes[.size] as? Int64) ?? 0
        let savings = inputSize > 0 ? (1.0 - Double(outputSize) / Double(inputSize)) * 100.0 : 0.0
        
        progressHandler?(CompressionProgress(progress: 1.0, currentBytes: outputSize, elapsedTime: Date().timeIntervalSince(startTime)))
        
        return (inputSize, outputSize, totalDurationSeconds, savings)
    }
}
