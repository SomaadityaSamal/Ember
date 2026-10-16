import Foundation
import FanIPC
import TelemetryBridge
import Darwin

@main enum FanHelperMain {
    static func main() {
        // Refuse a launch outside the approved launchd root service, or an unpinned build.
        guard geteuid() == 0,
              let raw = ember_embedded_client_requirement(),
              String(cString: raw).hasPrefix("identifier \"app.ember.heatmonitor.fanclient\" and cdhash ") else { exit(77) }
        let helper = FanHelper(requirement: String(cString: raw))
        withExtendedLifetime(helper) { helper.run() }
    }
}

final class FanHelper: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let requirement: String
    private let listener = NSXPCListener(machServiceName: FanServiceIdentity.machService)
    private let queue = DispatchQueue(label: "app.ember.fans.hardware")
    private let lock = NSLock()
    private var activeConnection: NSXPCConnection?
    private var hardware: UInt32 = 0
    private var maximum = false
    private var deadline: ContinuousClock.Instant?
    private var watchdog: DispatchSourceTimer?
    init(requirement: String) { self.requirement = requirement; super.init() }
    func run() {
        hardware = ember_smc_open()
        listener.delegate = self
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let deadline = self.deadline, ContinuousClock.now >= deadline else { return }
            self.restore()
        }
        watchdog = timer; timer.resume()
        // Signal handlers unwind manual control on normal service termination.
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.restore(); exit(0) }
            source.resume(); signals.append(source)
        }
        listener.resume()
        dispatchMain()
    }
    private var signals: [DispatchSourceSignal] = []
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only the current console user, running the exact approved app build, can connect.
        var console = stat()
        guard stat("/dev/console", &console) == 0, console.st_uid > 0,
              connection.effectiveUserIdentifier == console.st_uid else { return false }
        lock.lock(); defer { lock.unlock() }
        guard activeConnection == nil else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: FanService.self)
        connection.exportedObject = FanPeer(helper: self)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.restore()
                self.lock.lock(); self.activeConnection = nil; self.lock.unlock()
            }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        activeConnection = connection
        connection.resume()
        return true
    }
    func apply(_ enabled: Bool, reply: @escaping @Sendable (Int32, Bool) -> Void) {
        queue.async {
            if !enabled {
                let status = self.restore()
                reply(status, self.maximum); return
            }
            guard self.hardware != 0 else { reply(ENODEV, false); return }
            let status: Int32
            if self.maximum && ember_fans_verify_max(self.hardware) { status = 0 }
            else { status = ember_fans_max(self.hardware) }
            self.maximum = status == 0
            // Even a failed partial write may need another restoration attempt.
            self.deadline = ContinuousClock.now.advanced(by: .seconds(self.maximum ? 45 : 1))
            reply(status, self.maximum)
        }
    }
    @discardableResult private func restore() -> Int32 {
        let result = ember_fans_restore(hardware)
        if result == 0 { maximum = false; deadline = nil }
        else { deadline = ContinuousClock.now.advanced(by: .seconds(1)) }
        return result
    }
}
final class FanPeer: NSObject, FanService, @unchecked Sendable {
    private weak var helper: FanHelper?
    init(helper: FanHelper) { self.helper = helper }
    func setMaximum(_ enabled: Bool, reply: @escaping @Sendable (Int32, Bool) -> Void) {
        guard let helper else { reply(ENOTCONN, false); return }
        helper.apply(enabled, reply: reply)
    }
}
