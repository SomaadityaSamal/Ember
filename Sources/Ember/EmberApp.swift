import AppKit
import SwiftUI
import HeatCore
import ServiceManagement
import FanIPC

@main struct EmberApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--unregister-fan-helper") {
            do { try SMAppService.daemon(plistName: FanServiceIdentity.plist).unregister(); print("Fan helper unregistered") }
            catch { print("Fan helper unregister failed: \(error.localizedDescription)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--register-fan-helper") {
            do { try SMAppService.daemon(plistName: FanServiceIdentity.plist).register(); print("Fan helper registration submitted") }
            catch { print("Fan helper registration: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            diagnose(); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    @MainActor private static func diagnose() {
        let reader = TelemetryReader()
        let s = reader.sensors()
        print("Ember hardware diagnostic")
        print("SMC connected: \(s.connected)")
        for (label, values) in [("CPU", s.cpu), ("GPU", s.gpu), ("SoC", s.soc), ("Battery", s.battery), ("Fan RPM", s.fans)] {
            print("\(label): " + values.map { "\($0.key)=\(String(format: "%.1f", $0.value))" }.joined(separator: ", "))
        }
        print("Fan count: \(s.fanCount.map(String.init) ?? "unavailable")")
        _ = reader.processes(at: ProcessInfo.processInfo.systemUptime, foreground: nil)
        Thread.sleep(forTimeInterval: 1)
        let p = reader.processes(at: ProcessInfo.processInfo.systemUptime, foreground: nil)
        print("Readable processes: \(p.readable)/\(p.total)")
        for row in p.activities.prefix(10) { print(String(format: "%@ CPU=%.1f%% estimated-share=%.1f%% processes=%d", row.name, row.cpu, row.share, row.members.count)) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: Monitor!
    private let popover = NSPopover()
    private var indicator: StatusIndicator!
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = Monitor()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            indicator = StatusIndicator(frame: NSRect(x: 0, y: 0, width: 28, height: 22))
            indicator.isHidden = false
            button.addSubview(indicator)
            button.target = self; button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Ember thermal monitor")
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 460, height: 740)
        popover.contentViewController = NSHostingController(rootView: Dashboard(monitor: monitor))
        monitor.onUpdate = { [weak self] in self?.updateStatus() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let shouldConsume: Bool = MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return false }
                if event.type == .keyDown && event.keyCode == 53 { self.popover.performClose(nil); return true }
                if event.type != .keyDown && event.window != self.popover.contentViewController?.view.window && event.window != self.statusItem.button?.window {
                    self.popover.performClose(nil)
                }
                return false
            }
            return shouldConsume ? nil : event
        }
        updateStatus()
        if CommandLine.arguments.contains("--repair-fan-helper") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.monitor.fans.repair() }
        }
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.togglePopover() } }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.saveSnapshot(path) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { monitor.fans.shutdown() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return false
    }
    func popoverDidShow(_ notification: Notification) { monitor.panelVisible = true }
    func popoverDidClose(_ notification: Notification) { monitor.panelVisible = false }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    private func updateStatus() {
        guard let button = statusItem.button else { return }
        indicator.level = monitor.level
        indicator.paused = !monitor.sampling
        let showTop = monitor.sampling && monitor.showCulprit && (monitor.level == .warm || monitor.level == .hot || monitor.sensors.fansSpinning)
        let name = showTop ? monitor.top?.name : nil
        let compactName = name.map { $0.count > 17 ? String($0.prefix(16)) + "…" : $0 }
        let temperature = monitor.displayTemperature.map { "\(Int($0.rounded()))°" }
        let title = [temperature, compactName].compactMap { $0 }.joined(separator: " · ")
        if !button.title.isEmpty { button.title = "" }
        // Keep the indicator in its own view so pulsing does not redraw text.
        let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]).width
        let length = title.isEmpty ? 28 : textWidth + 38
        if statusItem.length != length { statusItem.length = length }
        indicator.frame = NSRect(x: 0, y: 0, width: statusItem.length, height: 22)
        indicator.title = title
        indicator.updateAppearance(animated: monitor.animate && monitor.sampling && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        button.toolTip = "Ember · \(monitor.sampling ? monitor.level.title : "Paused")\n\(name.map { "Top CPU contributor: \($0)" } ?? "Click for temperatures and activity")"
        button.setAccessibilityValue("\(monitor.level.title), \(temperature ?? "temperature unavailable")\(name.map { ", top contributor \($0)" } ?? "")")
    }
    private func saveSnapshot(_ path: String) {
        let host = NSHostingView(rootView: AnyView(Dashboard(monitor: monitor)))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 740)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
        host.rootView = AnyView(EmptyView())
    }
}

@MainActor final class StatusIndicator: NSView {
    var level = HeatLevel.unknown
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var paused = false
    private let glyph = SymbolMotionView(frame: NSRect(x: 5, y: 2, width: 20, height: 18))
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(glyph)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // Let the enclosing status button receive clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func updateAppearance(animated: Bool) {
        let speed = level == .hot ? 2.8 : level == .warm ? 1.7 : 0.9
        glyph.configure(name: paused ? "pause.circle" : level == .cool ? "leaf.fill" : "flame.fill",
                        pointSize: 13, color: paused ? .secondaryLabelColor : NSColor(level.color),
                        rotating: false, pulseDuration: animated && !paused ? .pi / speed : nil, weight: .medium)
    }
    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
        let sizeOfText = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 29, y: (22 - sizeOfText.height) / 2), withAttributes: attrs)
    }
}
