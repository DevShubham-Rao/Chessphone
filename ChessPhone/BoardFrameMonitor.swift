import CoreGraphics
import UIKit

/// A compact grayscale fingerprint used to notice motion in the glasses preview.
/// It does not identify chess pieces; it only decides when a fresh board read is useful.
enum BoardFrameMonitor {
    private static let side = 32

    static func fingerprint(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return rendered ? pixels : nil
    }

    /// Fraction of sampled pixels that changed enough to count as motion.
    static func changedFraction(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1 }
        let changed = zip(lhs, rhs).reduce(into: 0) { count, pair in
            if abs(Int(pair.0) - Int(pair.1)) > 22 { count += 1 }
        }
        return Double(changed) / Double(lhs.count)
    }
}
