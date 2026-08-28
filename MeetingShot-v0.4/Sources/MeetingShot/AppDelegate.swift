import AppKit
import CoreGraphics
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ControlWindowActionDelegate {
    private let initialDelay: TimeInterval = 3.0
    private let sampleInterval: TimeInterval = 1.0
    private let stableDelay: TimeInterval = 0.9
    private let fallbackInterval: TimeInterval = 30.0

    // 这些阈值只作用于 120×68 灰度缩略图的中央 84% 区域。
    private let changedRatioThreshold = 0.085
    private let meanDifferenceThreshold = 5.0
    private let strongMeanDifferenceThreshold = 12.0

    private let defaults = UserDefaults.standard
    private let screenshotService = ScreenshotService()
    private let workerQueue = DispatchQueue(label: "com.frank.meetingshot.capture")

    private var controlWindow: ControlWindowController!
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var captureNowMenuItem: NSMenuItem!
    private var openFolderMenuItem: NSMenuItem!
    private var exportPDFMenuItem: NSMenuItem!

    private var tickerTimer: Timer?
    private var recordingActive = false
    private var operationInProgress = false
    private var currentOperationID: UUID?
    private var sessionToken: UUID?

    private var screenshotCount = 0
    private var changeCaptureCount = 0
    private var fallbackCaptureCount = 0
    private var manualCaptureCount = 0
    private var currentSessionFolder: URL?
    private var saveFolder: URL!
    private var recordingStartDate: Date?
    private var analysisStartDate: Date?
    private var nextSampleDate: Date?
    private var lastSavedAt: Date?

    private var previousPreview: PreviewFrame?
    private var lastSavedPreview: PreviewFrame?
    private var pendingChange = false
    private var stableSampleCount = 0
    private var lastSignificantChangeAt: Date?
    private var latestDifference: FrameDifference?
    private var statusText = "尚未开始"

    private enum Keys {
        static let saveFolder = "saveFolder"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSettings()
        createApplicationMenu()
        createStatusItem()
        createControlWindow()
        observeSystemEvents()
        refreshInterface()
        controlWindow.showAndActivate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        invalidateTimer()
        sessionToken = nil
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        controlWindow.showAndActivate()
        return true
    }

    private func loadSettings() {
        if let path = defaults.string(forKey: Keys.saveFolder), !path.isEmpty {
            saveFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveFolder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures", isDirectory: true)
                .appendingPathComponent("MeetingShots", isDirectory: true)
        }

        try? FileManager.default.createDirectory(
            at: saveFolder,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func createApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "关于 MeetingShot",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "隐藏 MeetingShot",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "退出 MeetingShot",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    private func createControlWindow() {
        controlWindow = ControlWindowController()
        controlWindow.actionDelegate = self
        controlWindow.configure(saveFolder: saveFolder)
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        statusItem.button?.toolTip = "MeetingShot"

        let menu = NSMenu()
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        let showItem = NSMenuItem(
            title: "显示 MeetingShot",
            action: #selector(showControlWindow),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)

        toggleMenuItem = NSMenuItem(
            title: "开始截图",
            action: #selector(toggleRecordingFromMenu),
            keyEquivalent: "r"
        )
        toggleMenuItem.keyEquivalentModifierMask = [.command, .shift]
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        captureNowMenuItem = NSMenuItem(
            title: "立即补截",
            action: #selector(captureNowFromMenu),
            keyEquivalent: "s"
        )
        captureNowMenuItem.keyEquivalentModifierMask = [.command, .shift]
        captureNowMenuItem.target = self
        menu.addItem(captureNowMenuItem)

        openFolderMenuItem = NSMenuItem(
            title: "打开保存目录",
            action: #selector(openFolderFromMenu),
            keyEquivalent: ""
        )
        openFolderMenuItem.target = self
        menu.addItem(openFolderMenuItem)

        exportPDFMenuItem = NSMenuItem(
            title: "合并为 PDF",
            action: #selector(exportPDFFromMenu),
            keyEquivalent: ""
        )
        exportPDFMenuItem.target = self
        menu.addItem(exportPDFMenuItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(
            title: "退出 MeetingShot",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func observeSystemEvents() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshInterface()
    }

    func controlWindowDidRequestToggleRecording() {
        if recordingActive {
            stopRecording(showSummary: true)
        } else {
            startRecording()
        }
    }

    func controlWindowDidRequestCaptureNow() {
        captureHighResolution(reason: .manual)
    }

    func controlWindowDidRequestOpenFolder() {
        openCurrentFolder()
    }

    func controlWindowDidRequestChooseFolder() {
        chooseSaveFolder()
    }

    func controlWindowDidRequestExportPDF() {
        exportCurrentSessionPDF()
    }

    private func startRecording() {
        guard !recordingActive else { return }
        guard !operationInProgress else {
            statusText = "请等待当前截图操作完成"
            refreshInterface()
            return
        }
        guard ensureScreenPermission() else {
            statusText = "请先授予屏幕录制权限"
            refreshInterface()
            return
        }

        do {
            let folder = try screenshotService.beginSession(baseFolder: saveFolder)
            let now = Date()
            let token = UUID()

            currentSessionFolder = folder
            sessionToken = token
            screenshotCount = 0
            changeCaptureCount = 0
            fallbackCaptureCount = 0
            manualCaptureCount = 0
            recordingActive = true
            recordingStartDate = now
            analysisStartDate = now.addingTimeInterval(initialDelay)
            nextSampleDate = analysisStartDate
            lastSavedAt = nil
            previousPreview = nil
            lastSavedPreview = nil
            pendingChange = false
            stableSampleCount = 0
            lastSignificantChangeAt = nil
            latestDifference = nil
            statusText = "已开始 · 3 秒后保存首张并建立画面基准"

            startTicker()
            refreshInterface()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self,
                      self.recordingActive,
                      self.sessionToken == token else { return }
                self.controlWindow.hideWindow()
            }
        } catch {
            statusText = "无法开始：\(error.localizedDescription)"
            refreshInterface()
            showAlert(title: "无法开始截图", message: error.localizedDescription)
        }
    }

    private func stopRecording(showSummary: Bool) {
        guard recordingActive || tickerTimer != nil else { return }

        invalidateTimer()
        recordingActive = false
        sessionToken = nil
        nextSampleDate = nil
        analysisStartDate = nil
        pendingChange = false
        stableSampleCount = 0
        statusText = "已停止 · 本次保存 \(screenshotCount) 张"
        refreshInterface()

        if showSummary, let folder = currentSessionFolder {
            showCompletionSummary(folder: folder)
        }
    }

    private func startTicker() {
        invalidateTimer()
        tickerTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(tickerFired),
            userInfo: nil,
            repeats: true
        )
        if let timer = tickerTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func tickerFired() {
        guard recordingActive else { return }
        let now = Date()

        if !operationInProgress,
           let nextDate = nextSampleDate,
           now >= nextDate {
            nextSampleDate = now.addingTimeInterval(sampleInterval)

            if lastSavedAt == nil {
                captureHighResolution(reason: .initial)
            } else if let savedAt = lastSavedAt,
                      now.timeIntervalSince(savedAt) >= fallbackInterval {
                captureHighResolution(reason: .fallback)
            } else {
                sampleCurrentFrame()
            }
        }

        refreshInterface()
    }

    private func sampleCurrentFrame() {
        guard recordingActive,
              !operationInProgress,
              let token = sessionToken else { return }

        let operationID = UUID()
        operationInProgress = true
        currentOperationID = operationID

        workerQueue.async { [weak self] in
            guard let self = self else { return }
            let result: Result<PreviewFrame, Error>
            do {
                result = .success(try self.screenshotService.capturePreview())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.finishOperation(operationID)
                guard self.recordingActive,
                      self.sessionToken == token else { return }

                switch result {
                case .success(let frame):
                    self.processPreview(frame, at: Date())
                case .failure(let error):
                    self.handleCaptureError(error)
                }
            }
        }
    }

    private func processPreview(_ frame: PreviewFrame, at now: Date) {
        guard recordingActive else { return }

        guard let previous = previousPreview else {
            previousPreview = frame
            statusText = "监测中 · 已建立低清画面基准"
            refreshInterface()
            return
        }

        let frameDifference = screenshotService.difference(
            between: previous,
            and: frame
        )
        latestDifference = frameDifference
        let significant = isSignificantChange(frameDifference)

        if significant {
            pendingChange = true
            stableSampleCount = 0
            lastSignificantChangeAt = now
            statusText = "检测到画面变化 · 等待稳定 · \(frameDifference.diagnosticText)"
        } else if pendingChange {
            stableSampleCount += 1
            let stableFor = now.timeIntervalSince(lastSignificantChangeAt ?? now)

            if stableSampleCount >= 1 && stableFor >= stableDelay {
                let changedFromSaved: Bool
                if let savedPreview = lastSavedPreview {
                    let savedDifference = screenshotService.difference(
                        between: savedPreview,
                        and: frame
                    )
                    changedFromSaved = isSignificantChange(savedDifference)
                } else {
                    changedFromSaved = true
                }

                pendingChange = false
                stableSampleCount = 0
                lastSignificantChangeAt = nil
                previousPreview = frame

                if changedFromSaved {
                    statusText = "画面已稳定 · 正在保存高清截图"
                    refreshInterface()
                    captureHighResolution(reason: .change)
                    return
                } else {
                    statusText = "变化已稳定，但与最近截图相同 · 继续监测"
                }
            } else {
                statusText = "画面正在稳定 · \(frameDifference.diagnosticText)"
            }
        } else {
            statusText = "监测中 · \(frameDifference.diagnosticText)"
        }

        previousPreview = frame
        refreshInterface()
    }

    private func isSignificantChange(_ difference: FrameDifference) -> Bool {
        let broadChange = difference.changedRatio >= changedRatioThreshold
            && difference.meanDifference >= meanDifferenceThreshold
        let strongChange = difference.meanDifference >= strongMeanDifferenceThreshold
        return broadChange || strongChange
    }

    private func captureHighResolution(reason: CaptureReason) {
        guard recordingActive,
              !operationInProgress,
              let folder = currentSessionFolder,
              let token = sessionToken else {
            if recordingActive && operationInProgress && reason == .manual {
                statusText = "正在处理当前画面，请稍后再补截"
                refreshInterface()
            }
            return
        }

        let operationID = UUID()
        operationInProgress = true
        currentOperationID = operationID

        workerQueue.async { [weak self] in
            guard let self = self else { return }
            let result: Result<CaptureOutcome, Error>
            do {
                result = .success(
                    try self.screenshotService.captureFull(
                        into: folder,
                        reason: reason
                    )
                )
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.finishOperation(operationID)

                guard self.recordingActive,
                      self.sessionToken == token else {
                    if case .success(let outcome) = result {
                        try? FileManager.default.removeItem(at: outcome.savedFile)
                    }
                    return
                }

                switch result {
                case .success(let outcome):
                    self.screenshotCount += 1
                    switch reason {
                    case .change:
                        self.changeCaptureCount += 1
                    case .fallback:
                        self.fallbackCaptureCount += 1
                    case .manual:
                        self.manualCaptureCount += 1
                    case .initial:
                        break
                    }

                    let now = Date()
                    self.lastSavedAt = now
                    self.lastSavedPreview = outcome.preview
                    self.previousPreview = outcome.preview
                    self.pendingChange = false
                    self.stableSampleCount = 0
                    self.lastSignificantChangeAt = nil
                    self.nextSampleDate = now.addingTimeInterval(self.sampleInterval)

                    switch reason {
                    case .initial:
                        self.statusText = "首张已保存 · 正在监测画面变化"
                    case .change:
                        self.statusText = "检测到翻页候选并已保存 · 共 \(self.screenshotCount) 张"
                    case .fallback:
                        self.statusText = "30 秒兜底截图已保存 · 共 \(self.screenshotCount) 张"
                    case .manual:
                        self.statusText = "已手动补截 · 共 \(self.screenshotCount) 张"
                    }
                    self.refreshInterface()

                case .failure(let error):
                    self.handleCaptureError(error)
                }
            }
        }
    }

    private func finishOperation(_ operationID: UUID) {
        if currentOperationID == operationID {
            operationInProgress = false
            currentOperationID = nil
        }
    }

    private func handleCaptureError(_ error: Error) {
        if let meetingError = error as? MeetingShotError {
            switch meetingError {
            case .screenPermissionMissing:
                stopRecording(showSummary: false)
                statusText = "截图已停止：缺少屏幕录制权限"
                refreshInterface()
                showPermissionAlert()
            case .insufficientDiskSpace:
                stopRecording(showSummary: false)
                statusText = "截图已停止：磁盘空间不足"
                refreshInterface()
                showAlert(
                    title: "磁盘空间不足",
                    message: "请清理磁盘空间或更换保存目录后再开始。"
                )
            default:
                statusText = "截图失败：\(meetingError.localizedDescription)"
                refreshInterface()
            }
        } else {
            statusText = "截图失败：\(error.localizedDescription)"
            refreshInterface()
        }
    }

    private func chooseSaveFolder() {
        guard !recordingActive else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择会议截图保存目录"
        panel.directoryURL = saveFolder

        if panel.runModal() == .OK, let url = panel.url {
            saveFolder = url
            defaults.set(url.path, forKey: Keys.saveFolder)
            try? FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
            statusText = "保存目录已更改"
            controlWindow.updateFolder(url)
            refreshInterface()
        }
    }

    private func openCurrentFolder() {
        guard let folder = currentSessionFolder ?? saveFolder else { return }
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: nil
        )
        NSWorkspace.shared.open(folder)
    }

    private func exportCurrentSessionPDF() {
        guard !recordingActive, let folder = currentSessionFolder else { return }

        do {
            let pdfURL = try screenshotService.exportPDF(from: folder)
            statusText = "PDF 已生成：\(pdfURL.lastPathComponent)"
            refreshInterface()

            let alert = NSAlert()
            alert.messageText = "PDF 已生成"
            alert.informativeText = pdfURL.path
            alert.alertStyle = .informational
            alert.addButton(withTitle: "打开 PDF")
            alert.addButton(withTitle: "打开文件夹")
            alert.addButton(withTitle: "关闭")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(pdfURL)
            } else if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(folder)
            }
        } catch {
            showAlert(title: "无法生成 PDF", message: error.localizedDescription)
        }
    }

    private func showCompletionSummary(folder: URL) {
        let alert = NSAlert()
        alert.messageText = "方案二测试已结束"
        alert.informativeText = "时长：\(formattedElapsed(from: recordingStartDate))\n总截图：\(screenshotCount) 张\n画面变化触发：\(changeCaptureCount) 张\n30 秒兜底：\(fallbackCaptureCount) 张\n手动补截：\(manualCaptureCount) 张\n\n位置：\(folder.path)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开文件夹")
        alert.addButton(withTitle: "合并为 PDF")
        alert.addButton(withTitle: "关闭")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(folder)
        } else if response == .alertSecondButtonReturn {
            exportCurrentSessionPDF()
        }
    }

    private func ensureScreenPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        let granted = CGRequestScreenCaptureAccess()
        if granted || CGPreflightScreenCaptureAccess() {
            return true
        }

        showPermissionAlert()
        return false
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 MeetingShot。授权后通常需要退出并重新打开应用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshInterface() {
        guard controlWindow != nil else { return }

        controlWindow.updateState(
            recording: recordingActive,
            status: statusText,
            elapsed: recordingActive ? formattedElapsed(from: recordingStartDate) : "--",
            savedCount: screenshotCount,
            fallbackCountdown: recordingActive ? formattedFallbackCountdown() : "--",
            canExportPDF: currentSessionFolder != nil && screenshotCount > 0
        )

        statusMenuItem?.title = statusText
        toggleMenuItem?.title = recordingActive ? "停止截图" : "开始截图"
        captureNowMenuItem?.isEnabled = recordingActive && !operationInProgress
        openFolderMenuItem?.title = currentSessionFolder == nil
            ? "打开保存目录"
            : "打开本次截图目录"
        exportPDFMenuItem?.isEnabled = !recordingActive
            && currentSessionFolder != nil
            && screenshotCount > 0
        updateStatusIcon()
    }

    private func formattedFallbackCountdown() -> String {
        let targetDate: Date?
        if let savedAt = lastSavedAt {
            targetDate = savedAt.addingTimeInterval(fallbackInterval)
        } else {
            targetDate = analysisStartDate
        }

        guard let target = targetDate else { return "--" }
        let remaining = max(0, Int(ceil(target.timeIntervalSinceNow)))
        return "\(remaining) 秒"
    }

    private func formattedElapsed(from date: Date?) -> String {
        guard let date = date else { return "--" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func updateStatusIcon() {
        guard statusItem != nil, let button = statusItem.button else { return }

        if #available(macOS 11.0, *) {
            let symbol = recordingActive ? "record.circle.fill" : "camera.fill"
            button.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: "MeetingShot"
            )
        } else {
            button.title = recordingActive ? "⏺" : "📷"
        }
    }

    private func invalidateTimer() {
        tickerTimer?.invalidate()
        tickerTimer = nil
    }

    @objc private func screenParametersChanged() {
        guard recordingActive else { return }
        previousPreview = nil
        lastSavedPreview = nil
        pendingChange = false
        stableSampleCount = 0
        lastSignificantChangeAt = nil
        nextSampleDate = Date().addingTimeInterval(1)
        statusText = "显示器配置已变化 · 正在重新建立画面基准"
        refreshInterface()
    }

    @objc private func systemDidWake() {
        guard recordingActive else { return }
        previousPreview = nil
        pendingChange = false
        stableSampleCount = 0
        lastSignificantChangeAt = nil
        nextSampleDate = Date().addingTimeInterval(1)
        statusText = "Mac 已唤醒 · 正在重新建立画面基准"
        refreshInterface()
    }

    @objc private func showControlWindow() {
        controlWindow.showAndActivate()
    }

    @objc private func toggleRecordingFromMenu() {
        controlWindowDidRequestToggleRecording()
    }

    @objc private func captureNowFromMenu() {
        controlWindowDidRequestCaptureNow()
    }

    @objc private func openFolderFromMenu() {
        openCurrentFolder()
    }

    @objc private func exportPDFFromMenu() {
        exportCurrentSessionPDF()
    }

    @objc private func quitApplication() {
        if recordingActive {
            let alert = NSAlert()
            alert.messageText = "MeetingShot 正在截图"
            alert.informativeText = "退出将立即停止本次画面监测。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "停止并退出")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        stopRecording(showSummary: false)
        NSApplication.shared.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}
