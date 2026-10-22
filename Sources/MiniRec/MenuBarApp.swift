import Cocoa
import Foundation
import ScreenCaptureKit
import AVFoundation

@MainActor
public final class MiniRecApp: NSObject, NSApplicationDelegate {
    private static var sharedDelegate: MiniRecApp?
    
    private var statusItem: NSStatusItem!
    private var activeRecorder: ScreenRecorder?
    private var currentProfile: RecordingProfile = .compact
    private var recordAudio: Bool = true
    private var recordMicrophone: Bool = false
    private var showCursor: Bool = true
    private var copyToClipboard: Bool = true
    private var smartRetinaScale: Bool = false
    
    private var startItem: NSMenuItem!
    private var startWindowItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var resumeItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var statusTitleItem: NSMenuItem!
    
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var currentOutputFile: URL?
    
    public static func run() {
        let app = NSApplication.shared
        let delegate = MiniRecApp()
        self.sharedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Runs in menu bar without showing in Dock
        app.run()
    }
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
    }
    
    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "📹 MiniRec"
        }
        
        updateMenuState()
    }
    
    private func updateMenuState() {
        let menu = NSMenu()
        
        statusTitleItem = NSMenuItem(title: activeRecorder?.isRecording == true ? "● 錄影中..." : "MiniRec 螢幕錄影 (HEVC 極小體積)", action: nil, keyEquivalent: "")
        statusTitleItem.isEnabled = false
        menu.addItem(statusTitleItem)
        menu.addItem(NSMenuItem.separator())
        
        // Recording actions
        startItem = NSMenuItem(title: "⏺ 開始全螢幕錄影", action: #selector(startFullscreenRecording), keyEquivalent: "r")
        startItem.target = self
        startItem.isEnabled = (activeRecorder?.isRecording != true)
        menu.addItem(startItem)
        
        startWindowItem = NSMenuItem(title: "🪟 錄製指定視窗...", action: #selector(pickWindowAndRecord), keyEquivalent: "w")
        startWindowItem.target = self
        startWindowItem.isEnabled = (activeRecorder?.isRecording != true)
        menu.addItem(startWindowItem)
        
        pauseItem = NSMenuItem(title: "⏸ 暫停錄影", action: #selector(pauseRecording), keyEquivalent: "p")
        pauseItem.target = self
        pauseItem.isEnabled = (activeRecorder?.isRecording == true && activeRecorder?.isPaused == false)
        menu.addItem(pauseItem)
        
        resumeItem = NSMenuItem(title: "▶ 繼續錄影", action: #selector(resumeRecording), keyEquivalent: "u")
        resumeItem.target = self
        resumeItem.isEnabled = (activeRecorder?.isRecording == true && activeRecorder?.isPaused == true)
        menu.addItem(resumeItem)
        
        stopItem = NSMenuItem(title: "⏹ 停止並儲存錄影", action: #selector(stopRecording), keyEquivalent: "s")
        stopItem.target = self
        stopItem.isEnabled = (activeRecorder?.isRecording == true)
        menu.addItem(stopItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Screenshot actions
        let screenshotHeader = NSMenuItem(title: "📸 快速截圖 (自動複製至剪貼簿)", action: nil, keyEquivalent: "")
        screenshotHeader.isEnabled = false
        menu.addItem(screenshotHeader)
        
        let shotSelectItem = NSMenuItem(title: "✂️ 自定區域截圖 (框選)...", action: #selector(takeInteractiveScreenshot), keyEquivalent: "4")
        shotSelectItem.keyEquivalentModifierMask = [.command, .shift]
        shotSelectItem.target = self
        menu.addItem(shotSelectItem)
        
        let shotWindowItem = NSMenuItem(title: "🪟 視窗截圖...", action: #selector(takeWindowScreenshot), keyEquivalent: "5")
        shotWindowItem.keyEquivalentModifierMask = [.command, .shift]
        shotWindowItem.target = self
        menu.addItem(shotWindowItem)
        
        let shotFullItem = NSMenuItem(title: "🖥 全螢幕截圖", action: #selector(takeFullscreenScreenshot), keyEquivalent: "3")
        shotFullItem.keyEquivalentModifierMask = [.command, .shift]
        shotFullItem.target = self
        menu.addItem(shotFullItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quality Profiles Submenu
        let profileMenu = NSMenu()
        for p in RecordingProfile.allCases {
            let item = NSMenuItem(title: p.displayName, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p
            item.state = (p == currentProfile) ? .on : .off
            profileMenu.addItem(item)
        }
        let profileSubmenuItem = NSMenuItem(title: "⚙️ 畫質設定 (\(currentProfile.rawValue))", action: nil, keyEquivalent: "")
        profileSubmenuItem.submenu = profileMenu
        menu.addItem(profileSubmenuItem)
        
        // Settings Submenu
        let audioItem = NSMenuItem(title: "🔊 錄製系統音訊", action: #selector(toggleAudio), keyEquivalent: "")
        audioItem.target = self
        audioItem.state = recordAudio ? .on : .off
        menu.addItem(audioItem)
        
        let micItem = NSMenuItem(title: "🎤 錄製麥克風聲音 (語音旁白)", action: #selector(toggleMicrophone), keyEquivalent: "")
        micItem.target = self
        micItem.state = recordMicrophone ? .on : .off
        menu.addItem(micItem)
        
        let copyItem = NSMenuItem(title: "📋 錄完自動複製至剪貼簿", action: #selector(toggleCopy), keyEquivalent: "")
        copyItem.target = self
        copyItem.state = copyToClipboard ? .on : .off
        menu.addItem(copyItem)
        
        let retinaItem = NSMenuItem(title: "📐 Retina 0.5x 智慧縮放 (更小容量)", action: #selector(toggleRetina), keyEquivalent: "")
        retinaItem.target = self
        retinaItem.state = smartRetinaScale ? .on : .off
        menu.addItem(retinaItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Extra features
        let gifItem = NSMenuItem(title: "🎞 轉換影片為動畫 GIF...", action: #selector(openGIFConvertDialog), keyEquivalent: "g")
        gifItem.target = self
        menu.addItem(gifItem)
        
        let compressItem = NSMenuItem(title: "🗜 壓縮現有影片檔案...", action: #selector(openCompressFileDialog), keyEquivalent: "c")
        compressItem.target = self
        menu.addItem(compressItem)
        
        let openFolderItem = NSMenuItem(title: "📂 開啟錄影資料夾", action: #selector(openRecordingsFolder), keyEquivalent: "o")
        openFolderItem.target = self
        menu.addItem(openFolderItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "🚪 結束 MiniRec", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    // MARK: - Actions
    @objc private func startFullscreenRecording() {
        startRecording(target: .display(displayIndex: 0))
    }
    
    @objc private func pickWindowAndRecord() {
        Task {
            do {
                let (_, windows) = try await ScreenRecorder.getAvailableTargets()
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "選擇欲錄製的視窗"
                    alert.informativeText = "請從列表中選擇一個活動視窗："
                    
                    let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
                    for w in windows.prefix(20) {
                        let app = w.owningApplication?.applicationName ?? "未知"
                        let title = w.title ?? "無標題"
                        popUp.addItem(withTitle: "\(app) - \(title)")
                    }
                    alert.accessoryView = popUp
                    alert.addButton(withTitle: "開始錄製")
                    alert.addButton(withTitle: "取消")
                    
                    if alert.runModal() == .alertFirstButtonReturn {
                        let index = popUp.indexOfSelectedItem
                        if index >= 0 && index < windows.count {
                            let wid = windows[index].windowID
                            self.startRecording(target: .window(windowID: wid))
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
    
    private func startRecording(target: CaptureTarget) {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let timeStr = df.string(from: Date())
        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: ".")
        let fileURL = moviesDir.appendingPathComponent("MiniRec_\(timeStr).mp4")
        self.currentOutputFile = fileURL
        
        let recorder = ScreenRecorder(
            outputURL: fileURL,
            profile: currentProfile,
            target: target,
            recordAudio: recordAudio,
            recordMicrophone: recordMicrophone,
            showCursor: showCursor,
            customScale: smartRetinaScale ? 0.5 : nil
        )
        self.activeRecorder = recorder
        
        Task {
            do {
                try await recorder.start()
                await MainActor.run {
                    self.recordingStartTime = Date()
                    self.statusItem.button?.title = "🔴 00:00"
                    self.startTimer()
                    self.updateMenuState()
                }
            } catch {
                await MainActor.run {
                    self.activeRecorder = nil
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
    
    private func startTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.recordingStartTime else { return }
                let elapsed = Int(Date().timeIntervalSince(start))
                let min = elapsed / 60
                let sec = elapsed % 60
                if self.activeRecorder?.isPaused == true {
                    self.statusItem.button?.title = String(format: "⏸ %02d:%02d", min, sec)
                } else {
                    self.statusItem.button?.title = String(format: "🔴 %02d:%02d", min, sec)
                }
            }
        }
    }
    
    @objc private func pauseRecording() {
        activeRecorder?.pause()
        updateMenuState()
    }
    
    @objc private func resumeRecording() {
        activeRecorder?.resume()
        updateMenuState()
    }
    
    @objc private func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        statusItem.button?.title = "📹 MiniRec"
        
        guard let recorder = activeRecorder else { return }
        self.activeRecorder = nil
        self.updateMenuState()
        
        Task {
            do {
                let summary = try await recorder.stop()
                await MainActor.run {
                    // Reveal file in Finder
                    NSWorkspace.shared.activateFileViewerSelecting([summary.fileURL])
                    
                    if self.copyToClipboard {
                        ClipboardHelper.copyFile(at: summary.fileURL)
                    }
                    
                    let alert = NSAlert()
                    alert.messageText = "錄影已儲存完成！"
                    alert.informativeText = """
                    檔案名稱: \(summary.fileURL.lastPathComponent)
                    檔案大小: \(String(format: "%.2f MB", summary.fileSizeMB))
                    錄製品質: \(summary.profile.displayName)
                    長度: \(String(format: "%.1f 秒", summary.durationSeconds))
                    平均位元率: \(String(format: "%.0f kbps", summary.averageBitrateKbps))
                    \(self.copyToClipboard ? "📋 已自動複製檔案至剪貼簿 (可直接 Command+V 貼上)" : "")
                    
                    (已採用 Apple 晶片硬體 HEVC 高壓縮，相較內建錄影省下約 85%~90% 容量)
                    """
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "確定")
                    alert.runModal()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
    
    @objc private func selectProfile(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? RecordingProfile {
            self.currentProfile = p
            updateMenuState()
        }
    }
    
    @objc private func toggleAudio() {
        recordAudio.toggle()
        updateMenuState()
    }
    
    @objc private func toggleMicrophone() {
        recordMicrophone.toggle()
        updateMenuState()
    }
    
    @objc private func toggleCopy() {
        copyToClipboard.toggle()
        updateMenuState()
    }
    
    @objc private func toggleRetina() {
        smartRetinaScale.toggle()
        updateMenuState()
    }
    
    @objc private func openRecordingsFolder() {
        if let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(dir)
        }
    }
    
    @objc private func openGIFConvertDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.prompt = "選擇並轉換為 GIF"
        
        if panel.runModal() == .OK, let inputURL = panel.url {
            let baseName = inputURL.deletingPathExtension().lastPathComponent
            let dir = inputURL.deletingLastPathComponent()
            let outURL = dir.appendingPathComponent("\(baseName).gif")
            
            let alert = NSAlert()
            alert.messageText = "正在生成動畫 GIF..."
            alert.informativeText = "來源: \(inputURL.lastPathComponent)\n目標: \(outURL.lastPathComponent)\n請稍候..."
            alert.alertStyle = .informational
            
            Task {
                do {
                    let exporter = GIFExporter()
                    let config = GIFExporter.Config(fps: 12, maxWidth: 800, loopCount: 0)
                    let res = try await exporter.exportGIF(from: inputURL, to: outURL, config: config)
                    await MainActor.run {
                        NSWorkspace.shared.activateFileViewerSelecting([outURL])
                        if self.copyToClipboard {
                            ClipboardHelper.copyFile(at: outURL)
                        }
                        let doneAlert = NSAlert()
                        let sizeMB = Double(res.outputSize) / (1024 * 1024)
                        doneAlert.messageText = "GIF 生成完成！"
                        doneAlert.informativeText = """
                        檔案大小: \(String(format: "%.2f MB", sizeMB))
                        影格數量: \(res.frameCount) 幀
                        長度: \(String(format: "%.1f 秒", res.duration))
                        已儲存於: \(outURL.path)
                        \(self.copyToClipboard ? "📋 已複製 GIF 至剪貼簿" : "")
                        """
                        doneAlert.runModal()
                    }
                } catch {
                    await MainActor.run {
                        let errAlert = NSAlert(error: error)
                        errAlert.runModal()
                    }
                }
            }
        }
    }
    
    @objc private func openCompressFileDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.prompt = "選擇並壓縮"
        
        if panel.runModal() == .OK, let inputURL = panel.url {
            let baseName = inputURL.deletingPathExtension().lastPathComponent
            let dir = inputURL.deletingLastPathComponent()
            let outURL = dir.appendingPathComponent("\(baseName)_compressed.mp4")
            
            let alert = NSAlert()
            alert.messageText = "正在使用硬體加速壓縮影片..."
            alert.informativeText = "來源: \(inputURL.lastPathComponent)\n目標: \(outURL.lastPathComponent)\n請稍候..."
            alert.alertStyle = .informational
            
            Task {
                do {
                    let compressor = VideoCompressor()
                    let res = try await compressor.compress(inputURL: inputURL, outputURL: outURL, profile: self.currentProfile)
                    await MainActor.run {
                        NSWorkspace.shared.activateFileViewerSelecting([outURL])
                        if self.copyToClipboard {
                            ClipboardHelper.copyFile(at: outURL)
                        }
                        let doneAlert = NSAlert()
                        let inMB = Double(res.inputSize) / (1024 * 1024)
                        let outMB = Double(res.outputSize) / (1024 * 1024)
                        doneAlert.messageText = "壓縮完成！"
                        doneAlert.informativeText = """
                        原始大小: \(String(format: "%.2f MB", inMB))
                        壓縮後大小: \(String(format: "%.2f MB", outMB))
                        節省容量: \(String(format: "%.1f%%", res.savings))
                        已儲存於: \(outURL.path)
                        \(self.copyToClipboard ? "📋 已複製壓縮影片至剪貼簿" : "")
                        """
                        doneAlert.runModal()
                    }
                } catch {
                    await MainActor.run {
                        let errAlert = NSAlert(error: error)
                        errAlert.runModal()
                    }
                }
            }
        }
    }
    
    // MARK: - Screenshot Actions
    @objc private func takeInteractiveScreenshot() {
        captureScreenshot(target: .interactive)
    }
    
    @objc private func takeFullscreenScreenshot() {
        captureScreenshot(target: .fullscreen())
    }
    
    @objc private func takeWindowScreenshot() {
        Task {
            do {
                let (_, windows) = try await ScreenRecorder.getAvailableTargets()
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "選擇欲截圖的視窗"
                    alert.informativeText = "請從列表中選擇一個活動視窗進行高畫質截圖："
                    
                    let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
                    for w in windows.prefix(20) {
                        let app = w.owningApplication?.applicationName ?? "未知"
                        let title = w.title ?? "無標題"
                        popUp.addItem(withTitle: "\(app) - \(title)")
                    }
                    alert.accessoryView = popUp
                    alert.addButton(withTitle: "截圖")
                    alert.addButton(withTitle: "取消")
                    
                    if alert.runModal() == .alertFirstButtonReturn {
                        let index = popUp.indexOfSelectedItem
                        if index >= 0 && index < windows.count {
                            let wid = windows[index].windowID
                            self.captureScreenshot(target: .window(windowID: wid))
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
    
    private func captureScreenshot(target: ScreenshotTarget) {
        Task {
            let capturer = ScreenshotCapturer()
            do {
                let result = try await capturer.capture(target: target, copyToClipboard: copyToClipboard)
                await MainActor.run {
                    // Camera shutter sound effect
                    NSSound(named: NSSound.Name("Hero"))?.play()
                    
                    if let fileURL = result.fileURL {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                    
                    let alert = NSAlert()
                    alert.messageText = "📸 截圖完成！"
                    alert.informativeText = """
                    模式: \(result.targetDescription)
                    解析度: \(result.width) x \(result.height)
                    \(result.fileURL != nil ? "檔案儲存於: \(result.fileURL!.path)" : "")
                    \(self.copyToClipboard ? "📋 已自動複製至剪貼簿，可直接 Command+V 貼上" : "")
                    """
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "確定")
                    alert.runModal()
                }
            } catch {
                await MainActor.run {
                    if (error as NSError).code != 12 { // 12 = user cancelled
                        let alert = NSAlert(error: error)
                        alert.runModal()
                    }
                }
            }
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
