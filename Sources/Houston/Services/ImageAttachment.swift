import AppKit
import ImageIO

/// An image the user attached, encoded for Claude's stream-json user
/// message as a base64 `image` content block — the model sees the
/// picture in the message itself (a paste in the TUI, Claude desktop)
/// instead of having to Read a path off disk. Verified against the live
/// CLI 2026-10-20: a 64×64 PNG block answered "red", and the transcript
/// line keeps the block verbatim, which is what `ChatArchive` renders
/// back as a thumbnail.
///
/// Small web-format files pass through untouched; anything else — HEIC,
/// TIFF, BMP, an oversized Retina screenshot — is resampled to the API's
/// 1568px effective maximum and re-encoded, so one send doesn't cost
/// megabytes of transcript. nil means the bytes aren't a bitmap the
/// system can decode (SVG, a corrupt file); the caller keeps the path in
/// the text then, the old route.
enum ImageAttachment {
    struct Encoded: Sendable {
        let mediaType: String
        let base64: String
    }

    static let maxPixels: CGFloat = 1568
    private static let passThroughBytes = 3_000_000

    static func encode(path: String) -> Encoded? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let ext = url.pathExtension.lowercased()
        let webType: String? = switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        if let webType, data.count <= passThroughBytes, width > 0,
           max(width, height) <= maxPixels {
            return Encoded(mediaType: webType, base64: data.base64EncodedString())
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        // Photos re-encode as JPEG; screenshots and everything else as
        // PNG so UI text stays crisp.
        let photo = ["jpg", "jpeg", "heic", "heif"].contains(ext)
        let rep = NSBitmapImageRep(cgImage: cg)
        let out = photo
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            : rep.representation(using: .png, properties: [:])
        guard let out else { return nil }
        return Encoded(
            mediaType: photo ? "image/jpeg" : "image/png",
            base64: out.base64EncodedString()
        )
    }
}
