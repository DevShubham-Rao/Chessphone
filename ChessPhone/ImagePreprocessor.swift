import UIKit

/// Shrinks a photo so the longest edge is at most `maxEdge` pixels and encodes it as JPEG.
/// Smaller upload = lower latency on cellular, and a chessboard stays perfectly readable at 1024 px.
enum ImagePreprocessor {
    static var maxEdge: CGFloat = 1024
    static var jpegQuality: CGFloat = 0.8

    static func jpegData(from image: UIImage) throws -> Data {
        // UIImage.size is in points; convert to real pixels first.
        let pixelSize = CGSize(width: image.size.width * image.scale,
                               height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > 0 else { throw VisionError.imageEncodingFailed }

        let ratio = min(1, maxEdge / longest)          // never upscale
        let target = CGSize(width: (pixelSize.width * ratio).rounded(),
                            height: (pixelSize.height * ratio).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1                               // 1 point == 1 pixel in the output
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))   // also bakes in EXIF orientation
        }

        guard let data = resized.jpegData(compressionQuality: jpegQuality) else {
            throw VisionError.imageEncodingFailed
        }
        return data
    }
}
