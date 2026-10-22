import Foundation
import ScreenCaptureKit
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotTarget: Sendable {
    case fullscreen(displayIndex: Int = 0)
    case window(windowID: CGWindowID)
    case rect(CGRect)
    case interactive
}

public struct ScreenshotResult: Sendable {
    public let image: CGImage
    public let fileURL: URL?
    public let width: Int
    public let height: Int
    public let fileSizeBytes: Int64
    public let targetDescription: String
}

public final class ScreenshotCapturer: @unchecked Sendable {
    public init() {}
    
    public func capture(
        target: ScreenshotTarget = .interactive,
        outputURL: URL? = nil,
        saveToFile: Bool = true,
        copyToClipboard: Bool = true
    ) async throws -> ScreenshotResult {
        await MainActor.run {
            _ = NSApplication.shared
        }
        
        var finalURL: URL?
        if saveToFile {
            if let out = outputURL {
                finalURL = out
            } else {
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd_HHmmss"
                let timestamp = df.string(from: Date())
                let picsDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: ".")
                let screenshotsDir = picsDir.appendingPathComponent("Screenshots", isDirectory: true)
                try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
                finalURL = screenshotsDir.appendingPathComponent("Screenshot_\(timestamp).png")
            }
        }
        
        let (cgImage, description) = try await captureImage(for: target)
        
        var savedSize: Int64 = 0
        if let saveURL = finalURL {
            try? FileManager.default.removeItem(at: saveURL)
            guard let destination = CGImageDestinationCreateWithURL(
                saveURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw NSError(domain: "MiniRec", code: 10, userInfo: [NSLocalizedDescriptionKey: "無法建立截圖目標檔案: \(saveURL.path)"])
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw NSError(domain: "MiniRec", code: 11, userInfo: [NSLocalizedDescriptionKey: "儲存 PNG 截圖失敗"])
            }
            savedSize = (try? FileManager.default.attributesOfItem(atPath: saveURL.path)[.size] as? Int64) ?? 0
        }
        
        if copyToClipboard {
            await MainActor.run {
                ClipboardHelper.copyImage(cgImage, fileURL: finalURL)
            }
        }
        
        return ScreenshotResult(
            image: cgImage,
            fileURL: finalURL,
            width: cgImage.width,
            height: cgImage.height,
            fileSizeBytes: savedSize,
            targetDescription: description
        )
    }
    
    private func captureImage(for target: ScreenshotTarget) async throws -> (CGImage, String) {
        switch target {
        case .interactive:
            return try await captureViaInteractiveTool()
            
        case .fullscreen(let displayIndex):
            return try await captureFullscreen(displayIndex: displayIndex)
            
        case .window(let windowID):
            return try await captureWindow(windowID: windowID)
            
        case .rect(let rect):
            return try await captureCustomRect(rect: rect)
        }
    }
    
    private func captureViaInteractiveTool() async throws -> (CGImage, String) {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minirec_temp_\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: interactive (selection or press space for window)
        // -x: no sound
        process.arguments = ["-i", "-x", tempURL.path]
        
        try process.run()
        process.waitUntilExit()
        
        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw NSError(domain: "MiniRec", code: 12, userInfo: [NSLocalizedDescriptionKey: "使用者取消選取截圖"])
        }
        
        guard let source = CGImageSourceCreateWithURL(tempURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "MiniRec", code: 13, userInfo: [NSLocalizedDescriptionKey: "無法讀取互動截圖影像資料"])
        }
        
        return (cgImage, "自定區域/視窗 (互動選取)")
    }
    
    private func captureFullscreen(displayIndex: Int) async throws -> (CGImage, String) {
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard displayIndex < content.displays.count else {
                throw NSError(domain: "MiniRec", code: 14, userInfo: [NSLocalizedDescriptionKey: "找不到指定顯示器 (編號: \(displayIndex))"])
            }
            let display = content.displays[displayIndex]
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.showsCursor = false
            
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (image, "全螢幕 (顯示器 [\(displayIndex)])")
        } else {
            let displayID = CGMainDisplayID()
            guard let image = CGDisplayCreateImage(displayID) else {
                throw NSError(domain: "MiniRec", code: 15, userInfo: [NSLocalizedDescriptionKey: "全螢幕截圖失敗"])
            }
            return (image, "全螢幕 (主顯示器)")
        }
    }
    
    private func captureWindow(windowID: CGWindowID) async throws -> (CGImage, String) {
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let window = content.windows.first(where: { $0.windowID == windowID }) {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width)
                config.height = Int(window.frame.height)
                config.showsCursor = false
                
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let app = window.owningApplication?.applicationName ?? "視窗"
                let title = window.title ?? ""
                return (image, "指定視窗: \(app) - \(title)")
            }
        }
        
        // Fallback via CoreGraphics
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, options) else {
            throw NSError(domain: "MiniRec", code: 16, userInfo: [NSLocalizedDescriptionKey: "無法截取指定視窗 (ID: \(windowID))"])
        }
        return (image, "指定視窗 (ID: \(windowID))")
    }
    
    private func captureCustomRect(rect: CGRect) async throws -> (CGImage, String) {
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                throw NSError(domain: "MiniRec", code: 17, userInfo: [NSLocalizedDescriptionKey: "找不到活動顯示器"])
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = max(2, Int(rect.width))
            config.height = max(2, Int(rect.height))
            config.showsCursor = false
            
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (image, "自定區域矩形 (\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))")
        } else {
            guard let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution) else {
                throw NSError(domain: "MiniRec", code: 18, userInfo: [NSLocalizedDescriptionKey: "自定區域截圖失敗"])
            }
            return (image, "自定區域矩形 (\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))")
        }
    }
}
