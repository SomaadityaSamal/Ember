import AppKit

@MainActor final class AppIconCache {
    static let shared = AppIconCache()
    private final class Entry: NSObject {
        let image: NSImage
        let expires: TimeInterval
        init(image: NSImage, expires: TimeInterval) { self.image = image; self.expires = expires }
    }
    private let images = NSCache<NSString, Entry>()
    private init() {
        images.countLimit = 128
        images.totalCostLimit = 2 * 1024 * 1024
    }
    func icon(path: String, scale: CGFloat) -> NSImage {
        let scale = min(4, max(1, scale))
        let key = "\(scale):\(path)" as NSString
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = images.object(forKey: key), cached.expires > now { return cached.image }
        let original = NSWorkspace.shared.icon(forFile: path)
        let size = NSSize(width: 27, height: 27)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return original }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        context.imageInterpolation = .high
        original.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage else { return original }
        let image = NSImage(cgImage: cgImage, size: size)
        images.setObject(Entry(image: image, expires: now + 300), forKey: key,
                         cost: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return image
    }
}
