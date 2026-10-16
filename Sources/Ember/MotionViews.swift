import AppKit
import SwiftUI
import QuartzCore
import HeatCore

// Animate cached layers in the compositor. Sensor polls update their appearance;
// they do not drive frames or restart an animation that is already running.
@MainActor private enum LayerMotion {
    static func rotation(_ layer: CALayer, enabled: Bool, duration: Double) {
        let key = "ember.rotation"
        guard enabled else { layer.removeAnimation(forKey: key); return }
        guard layer.animation(forKey: key) == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = -Double.pi * 2
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: key)
    }
    static func pulse(_ layer: CALayer, duration: Double?, scale: Bool) {
        let key = "ember.pulse"
        guard let duration else { layer.removeAnimation(forKey: key); return }
        if layer.animation(forKey: key)?.duration == duration { return }
        let animation = CABasicAnimation(keyPath: scale ? "transform.scale" : "opacity")
        animation.fromValue = scale ? 0.965 : 0.66
        animation.toValue = scale ? 1.035 : 1
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key)
    }
}

struct SmoothSymbol: NSViewRepresentable {
    let name: String
    let pointSize: CGFloat
    let color: NSColor
    let rotating: Bool
    func makeNSView(context: Context) -> SymbolMotionView { SymbolMotionView(frame: .zero) }
    func updateNSView(_ view: SymbolMotionView, context: Context) {
        view.configure(name: name, pointSize: pointSize, color: color, rotating: rotating)
    }
    static func dismantleNSView(_ view: SymbolMotionView, coordinator: ()) { view.stop() }
}

@MainActor final class SymbolMotionView: NSView {
    private let symbolLayer = CALayer()
    private var symbolName = ""
    private var symbolSize: CGFloat = 0
    private var symbolWeight = NSFont.Weight.regular
    private var symbolColor: NSColor?
    private var imageSize = NSSize.zero
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(symbolLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var frame: NSRect { didSet { layoutSymbol() } }
    override var bounds: NSRect { didSet { layoutSymbol() } }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderSymbol()
    }
    override func layout() {
        super.layout()
        layoutSymbol()
    }
    private func layoutSymbol() {
        let scale = min(1, min(bounds.width / max(1, imageSize.width), bounds.height / max(1, imageSize.height)))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        symbolLayer.bounds = CGRect(origin: .zero, size: NSSize(width: imageSize.width * scale, height: imageSize.height * scale))
        symbolLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    private func renderSymbol() {
        guard let color = symbolColor,
              let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: symbolSize, weight: symbolWeight)) else { return }
        let scale = window?.backingScaleFactor ?? 2
        imageSize = image.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(ceil(imageSize.width * scale))), pixelsHigh: max(1, Int(ceil(imageSize.height * scale))),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = imageSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        let rect = CGRect(origin: .zero, size: imageSize)
        image.draw(in: rect)
        color.setFill(); rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        symbolLayer.contents = bitmap.cgImage
        symbolLayer.contentsScale = scale
        CATransaction.commit()
        layoutSymbol()
    }
    func configure(name: String, pointSize: CGFloat, color: NSColor, rotating: Bool,
                   pulseDuration: Double? = nil, scalePulse: Bool = false, weight: NSFont.Weight = .regular) {
        if symbolName != name || symbolSize != pointSize || symbolColor != color || symbolWeight != weight {
            symbolName = name; symbolSize = pointSize; symbolColor = color; symbolWeight = weight
            renderSymbol()
            setAccessibilityLabel(name == "fanblades.fill" ? "Fan" : name == "leaf.fill" ? "Leaf" : name == "flame.fill" ? "Flame" : "Paused")
        }
        LayerMotion.rotation(symbolLayer, enabled: rotating, duration: 2)
        LayerMotion.pulse(symbolLayer, duration: pulseDuration, scale: scalePulse)
    }
    func stop() { symbolLayer.removeAllAnimations() }
}

struct SmoothThermalOrb: NSViewRepresentable {
    let level: HeatLevel
    let animated: Bool
    func makeNSView(context: Context) -> ThermalMotionView { ThermalMotionView(frame: .zero) }
    func updateNSView(_ view: ThermalMotionView, context: Context) {
        view.configure(level: level, animated: animated)
    }
    static func dismantleNSView(_ view: ThermalMotionView, coordinator: ()) { view.stop() }
}

@MainActor final class ThermalMotionView: NSView {
    private let glow = CAGradientLayer()
    private let ring = CAShapeLayer()
    private let center = CAGradientLayer()
    private let orbit = CALayer()
    private let arc = CAShapeLayer()
    private let dot = CALayer()
    private let symbol = SymbolMotionView(frame: .zero)
    private var currentLevel: HeatLevel?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        for gradient in [glow, center] {
            gradient.type = .radial
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            gradient.masksToBounds = true
        }
        ring.fillColor = nil; ring.lineWidth = 1
        arc.fillColor = nil; arc.lineWidth = 1; arc.lineCap = .round
        arc.strokeStart = 0.08; arc.strokeEnd = 0.91
        root.addSublayer(glow); root.addSublayer(ring); root.addSublayer(center)
        root.addSublayer(orbit); orbit.addSublayer(arc); orbit.addSublayer(dot)
        dot.cornerRadius = 2
        addSubview(symbol)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for child in [glow, ring, center, orbit, arc, dot] {
            child.contentsScale = window?.backingScaleFactor ?? 2
        }
    }
    override func layout() {
        super.layout()
        // Only frame/layout changes touch these static paths, never animation ticks.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds; glow.cornerRadius = bounds.width / 2
        ring.frame = bounds; ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 5, dy: 5), transform: nil)
        center.frame = bounds.insetBy(dx: 20, dy: 20); center.cornerRadius = center.bounds.width / 2
        orbit.frame = bounds; arc.frame = orbit.bounds
        arc.path = CGPath(ellipseIn: orbit.bounds.insetBy(dx: 12, dy: 12), transform: nil)
        dot.frame = CGRect(x: bounds.midX - 2, y: bounds.midY + 48, width: 4, height: 4)
        symbol.frame = CGRect(x: bounds.midX - 24, y: bounds.midY - 25, width: 48, height: 50)
        CATransaction.commit()
    }
    func configure(level: HeatLevel, animated: Bool) {
        let color = NSColor(level.color)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Thermal state: \(level.title)")
        setAccessibilityChildren([])
        if currentLevel != level {
            currentLevel = level
            CATransaction.begin(); CATransaction.setDisableActions(true)
            glow.colors = [color.withAlphaComponent(0.13).cgColor, color.withAlphaComponent(0).cgColor]
            center.colors = [color.withAlphaComponent(0.16).cgColor, color.withAlphaComponent(0.025).cgColor]
            ring.strokeColor = color.withAlphaComponent(0.1).cgColor
            arc.strokeColor = color.withAlphaComponent(0.3).cgColor
            dot.backgroundColor = color.cgColor
            symbol.layer?.shadowColor = color.cgColor
            symbol.layer?.shadowRadius = 12; symbol.layer?.shadowOpacity = 0.35
            symbol.layer?.shadowOffset = .zero
            CATransaction.commit()
        }
        let speed = level == .hot ? 2.8 : level == .warm ? 1.7 : 0.9
        symbol.configure(name: level == .cool ? "leaf.fill" : "flame.fill", pointSize: 34,
                         color: color, rotating: false,
                         pulseDuration: animated ? .pi / speed : nil, scalePulse: true, weight: .light)
        LayerMotion.rotation(orbit, enabled: animated, duration: 72)
    }
    func stop() { orbit.removeAllAnimations(); symbol.stop() }
}
