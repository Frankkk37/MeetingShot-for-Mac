import AppKit
import Foundation

protocol ControlWindowActionDelegate: AnyObject {
    func controlWindowDidRequestToggleRecording()
    func controlWindowDidRequestCaptureNow()
    func controlWindowDidRequestOpenFolder()
    func controlWindowDidRequestChooseFolder()
    func controlWindowDidRequestExportPDF()
}

final class ControlWindowController: NSWindowController, NSWindowDelegate {
    weak var actionDelegate: ControlWindowActionDelegate?

    private let titleLabel = NSTextField(labelWithString: "MeetingShot")
    private let subtitleLabel = NSTextField(
        labelWithString: "方案二 MVP · 画面变化稳定后自动截图"
    )
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "尚未开始")
    private let folderLabel = NSTextField(labelWithString: "")
    private let chooseFolderButton = NSButton(title: "更改…", target: nil, action: nil)
    private let elapsedValue = NSTextField(labelWithString: "--")
    private let countValue = NSTextField(labelWithString: "0 张")
    private let fallbackValue = NSTextField(labelWithString: "--")
    private let startButton = NSButton(title: "开始截图", target: nil, action: nil)
    private let captureNowButton = NSButton(title: "立即补截", target: nil, action: nil)
    private let openFolderButton = NSButton(title: "打开文件夹", target: nil, action: nil)
    private let exportPDFButton = NSButton(title: "合并为 PDF", target: nil, action: nil)
    private let footerLabel = NSTextField(
        labelWithString: "开始后窗口会自动隐藏。可从菜单栏相机图标停止或立即补截。"
    )

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 570, height: 505),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MeetingShot"
        window.minSize = NSSize(width: 530, height: 485)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func showAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func hideWindow() {
        window?.orderOut(nil)
    }

    func configure(saveFolder: URL) {
        updateFolder(saveFolder)
    }

    func updateFolder(_ folder: URL) {
        folderLabel.stringValue = folder.path
        folderLabel.toolTip = folder.path
    }

    func updateState(
        recording: Bool,
        status: String,
        elapsed: String,
        savedCount: Int,
        fallbackCountdown: String,
        canExportPDF: Bool
    ) {
        statusLabel.stringValue = status
        statusLabel.toolTip = status
        elapsedValue.stringValue = elapsed
        countValue.stringValue = "\(savedCount) 张"
        fallbackValue.stringValue = fallbackCountdown

        startButton.title = recording ? "停止截图" : "开始截图"
        captureNowButton.isEnabled = recording
        chooseFolderButton.isEnabled = !recording
        exportPDFButton.isEnabled = !recording && canExportPDF

        statusDot.layer?.backgroundColor = (
            recording ? NSColor.systemRed : NSColor.secondaryLabelColor
        ).cgColor
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        statusLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail

        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [elapsedValue, countValue, fallbackValue].forEach {
            $0.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
            $0.alignment = .center
        }

        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(toggleRecording)

        captureNowButton.target = self
        captureNowButton.action = #selector(captureNow)
        captureNowButton.isEnabled = false

        openFolderButton.target = self
        openFolderButton.action = #selector(openFolder)

        exportPDFButton.target = self
        exportPDFButton.action = #selector(exportPDF)
        exportPDFButton.isEnabled = false

        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder)

        footerLabel.font = NSFont.systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center

        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        let statusRow = NSStackView(views: [statusDot, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let folderRow = formRow(
            title: "保存位置",
            contentViews: [folderLabel, chooseFolderButton]
        )

        let frequencyValue = NSTextField(labelWithString: "每 1 秒检查一次低清画面")
        let stableValue = NSTextField(labelWithString: "变化结束并稳定约 1 秒后保存")
        let fallbackSettingValue = NSTextField(labelWithString: "每 30 秒强制保存一次")
        [frequencyValue, stableValue, fallbackSettingValue].forEach {
            $0.textColor = .secondaryLabelColor
        }

        let settingsStack = NSStackView(views: [
            folderRow,
            formRow(title: "画面监测", contentViews: [frequencyValue]),
            formRow(title: "稳定判断", contentViews: [stableValue]),
            formRow(title: "兜底截图", contentViews: [fallbackSettingValue])
        ])
        settingsStack.orientation = .vertical
        settingsStack.spacing = 12
        settingsStack.alignment = .leading
        let settingsCard = card(containing: settingsStack)

        let stats = NSStackView(views: [
            statCard(title: "已运行", value: elapsedValue),
            statCard(title: "已保存", value: countValue),
            statCard(title: "距兜底", value: fallbackValue)
        ])
        stats.orientation = .horizontal
        stats.distribution = .fillEqually
        stats.spacing = 10

        let primaryButtons = NSStackView(views: [startButton, captureNowButton])
        primaryButtons.orientation = .horizontal
        primaryButtons.distribution = .fillEqually
        primaryButtons.spacing = 10
        startButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        captureNowButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let secondaryButtons = NSStackView(views: [openFolderButton, exportPDFButton])
        secondaryButtons.orientation = .horizontal
        secondaryButtons.distribution = .fillEqually
        secondaryButtons.spacing = 10

        let root = NSStackView(views: [
            header,
            statusRow,
            settingsCard,
            stats,
            primaryButtons,
            secondaryButtons,
            footerLabel
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 17
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            settingsCard.widthAnchor.constraint(equalTo: root.widthAnchor),
            stats.widthAnchor.constraint(equalTo: root.widthAnchor),
            primaryButtons.widthAnchor.constraint(equalTo: root.widthAnchor),
            secondaryButtons.widthAnchor.constraint(equalTo: root.widthAnchor),
            footerLabel.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func formRow(title: String, contentViews: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true

        var views: [NSView] = [label]
        views.append(contentsOf: contentViews)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func card(containing view: NSView) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }

    private func statCard(title: String, value: NSTextField) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.alignment = .center
        titleField.textColor = .secondaryLabelColor
        titleField.font = NSFont.systemFont(ofSize: 12)

        let stack = NSStackView(views: [titleField, value])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        return card(containing: stack)
    }

    @objc private func toggleRecording() {
        actionDelegate?.controlWindowDidRequestToggleRecording()
    }

    @objc private func captureNow() {
        actionDelegate?.controlWindowDidRequestCaptureNow()
    }

    @objc private func openFolder() {
        actionDelegate?.controlWindowDidRequestOpenFolder()
    }

    @objc private func chooseFolder() {
        actionDelegate?.controlWindowDidRequestChooseFolder()
    }

    @objc private func exportPDF() {
        actionDelegate?.controlWindowDidRequestExportPDF()
    }
}
