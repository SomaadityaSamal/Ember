import AppKit
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let bounds = NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: p * 0.20, yRadius: p * 0.20)
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1).setFill(); shape.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke(); shape.lineWidth = max(1, p / 150); shape.stroke()
        let halo = NSGradient(starting: NSColor(calibratedRed: 0.9, green: 0.29, blue: 0.08, alpha: 0.32), ending: .clear)!
        halo.draw(in: NSBezierPath(ovalIn: bounds.insetBy(dx: p * 0.05, dy: p * 0.05)), relativeCenterPosition: .zero)
        if let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: p * 0.50, weight: .regular)) {
            let rect = NSRect(x: p * 0.29, y: p * 0.23, width: p * 0.42, height: p * 0.57)
            let tinted = NSImage(size: flame.size, flipped: false) { bounds in
                flame.draw(in: bounds)
                NSColor(calibratedRed: 1, green: 0.65, blue: 0.30, alpha: 1).setFill()
                bounds.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
        }
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
