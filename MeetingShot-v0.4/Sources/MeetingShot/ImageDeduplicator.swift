
import AppKit
import Foundation

/// v0.4: 会后图片去重模块
/// 第一版采用轻量感知特征，不改变采集逻辑。
final class ImageDeduplicator {
    func selectRepresentativeImages(from urls: [URL]) -> [URL] {
        var result:[URL] = []
        var lastHash:[UInt8]? = nil
        for url in urls.sorted(by: {$0.lastPathComponent < $1.lastPathComponent}) {
            guard let hash = perceptualHash(url) else { continue }
            if let old = lastHash, distance(old, hash) <= 5 {
                // 相似图片：保留后续更稳定的一张
                if !result.isEmpty { result[result.count-1] = url }
            } else {
                result.append(url)
            }
            lastHash = hash
        }
        return result
    }

    private func perceptualHash(_ url: URL) -> [UInt8]? {
        guard let image = NSImage(contentsOf: url),
              let rep = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = CGSize(width: 8, height: 8)
        guard let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        ctx.draw(rep, in: CGRect(origin: .zero, size: size))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: 64)
        let avg = (0..<64).reduce(0) { $0 + Int(p[$1]) } / 64
        return (0..<64).map { p[$0] >= avg ? 1 : 0 }
    }

    private func distance(_ a:[UInt8], _ b:[UInt8]) -> Int {
        zip(a,b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }
}
