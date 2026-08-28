import Foundation

enum CaptureReason: String {
    case initial = "首次"
    case change = "变化"
    case fallback = "兜底"
    case manual = "手动"
}

struct PreviewFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

struct FrameDifference {
    let meanDifference: Double
    let changedRatio: Double

    var diagnosticText: String {
        return String(
            format: "平均差异 %.1f · 变化像素 %.1f%%",
            meanDifference,
            changedRatio * 100.0
        )
    }
}

struct CaptureOutcome {
    let savedFile: URL
    let preview: PreviewFrame
}

enum MeetingShotError: LocalizedError {
    case screenPermissionMissing
    case imageUnavailable
    case imageWriteFailed(URL)
    case saveFolderUnavailable
    case insufficientDiskSpace
    case noImagesForPDF
    case pdfWriteFailed

    var errorDescription: String? {
        switch self {
        case .screenPermissionMissing:
            return "尚未获得屏幕录制权限"
        case .imageUnavailable:
            return "无法读取主显示器画面"
        case .imageWriteFailed(let url):
            return "截图写入失败：\(url.lastPathComponent)"
        case .saveFolderUnavailable:
            return "无法创建或访问截图保存目录"
        case .insufficientDiskSpace:
            return "磁盘剩余空间不足，无法继续截图"
        case .noImagesForPDF:
            return "本次记录中没有可合并的 PNG 图片"
        case .pdfWriteFailed:
            return "PDF 生成失败"
        }
    }
}
