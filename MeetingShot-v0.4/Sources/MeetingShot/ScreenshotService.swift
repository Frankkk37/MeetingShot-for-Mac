import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

final class ScreenshotService {
    private let previewWidth = 120
    private let previewHeight = 68
    private let analysisCropRatio: CGFloat = 0.84
    private var captureSequence = 0

    func beginSession(baseFolder: URL) throws -> URL {
        captureSequence = 0

        do {
            try FileManager.default.createDirectory(
                at: baseFolder,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw MeetingShotError.saveFolderUnavailable
        }

        guard FileManager.default.isWritableFile(atPath: baseFolder.path) else {
            throw MeetingShotError.saveFolderUnavailable
        }

        let folderName = "\(timestampForFolder())_画面变化截图"
        let sessionFolder = uniqueFolder(
            baseFolder.appendingPathComponent(folderName, isDirectory: true)
        )

        do {
            try FileManager.default.createDirectory(
                at: sessionFolder,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw MeetingShotError.saveFolderUnavailable
        }

        return sessionFolder
    }

    func capturePreview() throws -> PreviewFrame {
        guard CGPreflightScreenCaptureAccess() else {
            throw MeetingShotError.screenPermissionMissing
        }
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            throw MeetingShotError.imageUnavailable
        }
        return try makePreview(from: image)
    }

    func captureFull(
        into folder: URL,
        reason: CaptureReason
    ) throws -> CaptureOutcome {
        guard CGPreflightScreenCaptureAccess() else {
            throw MeetingShotError.screenPermissionMissing
        }

        try ensureEnoughDiskSpace(for: folder)
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            throw MeetingShotError.imageUnavailable
        }

        let preview = try makePreview(from: image)
        captureSequence += 1
        let sequence = String(format: "%04d", captureSequence)
        let filename = "\(sequence)_\(timestampForFile())_\(reason.rawValue).png"
        let outputURL = uniqueFile(folder.appendingPathComponent(filename))
        try writePNG(image, to: outputURL)

        return CaptureOutcome(
            savedFile: outputURL,
            preview: preview
        )
    }

    func difference(
        between first: PreviewFrame,
        and second: PreviewFrame
    ) -> FrameDifference {
        guard first.width == second.width,
              first.height == second.height,
              first.pixels.count == second.pixels.count,
              !first.pixels.isEmpty else {
            return FrameDifference(meanDifference: 255, changedRatio: 1)
        }

        var totalDifference: Int64 = 0
        var changedPixels = 0
        let pixelChangeThreshold = 18

        for index in 0..<first.pixels.count {
            let difference = abs(Int(first.pixels[index]) - Int(second.pixels[index]))
            totalDifference += Int64(difference)
            if difference >= pixelChangeThreshold {
                changedPixels += 1
            }
        }

        let count = Double(first.pixels.count)
        return FrameDifference(
            meanDifference: Double(totalDifference) / count,
            changedRatio: Double(changedPixels) / count
        )
    }

    func exportPDF(from folder: URL) throws -> URL {
        let imageURLs: [URL]
        do {
            imageURLs = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw MeetingShotError.noImagesForPDF
        }

        guard !imageURLs.isEmpty else {
            throw MeetingShotError.noImagesForPDF
        }

        // v0.4: PDF 默认使用去重后的精选截图，原始 PNG 不删除。
        let selectedImages = ImageDeduplicator().selectRepresentativeImages(from: imageURLs)


        let document = PDFDocument()
        var pageIndex = 0

        for imageURL in selectedImages {
            autoreleasepool {
                guard let image = NSImage(contentsOf: imageURL),
                      let page = PDFPage(image: image) else {
                    return
                }
                document.insert(page, at: pageIndex)
                pageIndex += 1
            }
        }

        guard pageIndex > 0 else {
            throw MeetingShotError.noImagesForPDF
        }

        let outputURL = uniqueFile(
            folder.appendingPathComponent("会议精选版.pdf", isDirectory: false)
        )
        guard document.write(to: outputURL) else {
            throw MeetingShotError.pdfWriteFailed
        }
        return outputURL
    }

    private func makePreview(from image: CGImage) throws -> PreviewFrame {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let cropWidth = max(1, imageWidth * analysisCropRatio)
        let cropHeight = max(1, imageHeight * analysisCropRatio)
        let cropRect = CGRect(
            x: (imageWidth - cropWidth) / 2,
            y: (imageHeight - cropHeight) / 2,
            width: cropWidth,
            height: cropHeight
        ).integral

        guard let croppedImage = image.cropping(to: cropRect) else {
            throw MeetingShotError.imageUnavailable
        }

        var pixels = [UInt8](
            repeating: 0,
            count: previewWidth * previewHeight
        )
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let rendered = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: previewWidth,
                    height: previewHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: previewWidth,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }

            context.interpolationQuality = .low
            context.draw(
                croppedImage,
                in: CGRect(x: 0, y: 0, width: previewWidth, height: previewHeight)
            )
            return true
        }

        guard rendered else {
            throw MeetingShotError.imageUnavailable
        }

        return PreviewFrame(
            width: previewWidth,
            height: previewHeight,
            pixels: pixels
        )
    }

    private func ensureEnoughDiskSpace(for folder: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(
                forPath: folder.path
            )
            if let free = attributes[.systemFreeSize] as? NSNumber,
               free.int64Value < 100 * 1024 * 1024 {
                throw MeetingShotError.insufficientDiskSpace
            }
        } catch let error as MeetingShotError {
            throw error
        } catch {
            // 某些外接盘无法返回容量信息时，不阻止截图；写入失败会单独提示。
        }
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let pngType = "public.png" as CFString
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            pngType,
            1,
            nil
        ) else {
            throw MeetingShotError.imageWriteFailed(url)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MeetingShotError.imageWriteFailed(url)
        }
    }

    private func uniqueFolder(_ proposed: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposed.path) else {
            return proposed
        }

        var counter = 2
        while true {
            let candidate = proposed.deletingLastPathComponent()
                .appendingPathComponent(
                    "\(proposed.lastPathComponent)_\(counter)",
                    isDirectory: true
                )
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private func uniqueFile(_ proposed: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposed.path) else {
            return proposed
        }

        let base = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        var counter = 2
        while true {
            let candidate = proposed.deletingLastPathComponent()
                .appendingPathComponent("\(base)_\(counter)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private func timestampForFolder() -> String {
        return ScreenshotService.folderFormatter.string(from: Date())
    }

    private func timestampForFile() -> String {
        return ScreenshotService.fileFormatter.string(from: Date())
    }

    private static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH-mm-ss-SSS"
        return formatter
    }()
}
