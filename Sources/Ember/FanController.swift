import AppKit
import ServiceManagement
import Security
import FanIPC
import HeatCore

@MainActor final class FanController: ObservableObject {
    @Published private(set) var mode: FanMode = .automatic
    @Published private(set) var maximumActive = false
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var message = "macOS manages your fans"
    @Published var threshold = FanSettings.threshold(UserDefaults.standard.object(forKey: "fanThreshold") as? Double ?? 80) {
        didSet {
            let validated = FanSettings.threshold(threshold)
            if validated != threshold { threshold = validated; return }
            UserDefaults.standard.set(threshold, forKey: "fanThreshold"); evaluate()
        }
    }
    @Published private(set) var serviceStatus = SMAppService.daemon(plistName: FanServiceIdentity.plist).status
    private var policy = FanPolicy()
    private var connection: FanClientTransport?
    private var heartbeat: Timer?
    private var timeout: DispatchWorkItem?
    private var requestID = UUID()
    private var lastTemperature: Double?
    private var paused = false
    private var asleep = false
    private var lastSample: Date?
    private var service: SMAppService { .daemon(plistName: FanServiceIdentity.plist) }
    var installed: Bool { serviceStatus == .enabled }
    var conflictingController: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.crystalidea.macsfancontrol" }
    }
    init() {
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }
    func enable() {
        guard !conflictingController else { message = "Quit Macs Fan Control before giving Ember control."; return }
        do {
            try service.register()
            serviceStatus = service.status
            if serviceStatus == .requiresApproval {
                message = "Approve Ember’s fan helper in System Settings, then click Connect."
                SMAppService.openSystemSettingsLoginItems()
            } else if installed { connect() }
            else { message = "Fan helper is not yet enabled by macOS." }
        } catch {
            serviceStatus = service.status
            if serviceStatus == .requiresApproval {
                message = "macOS needs approval for Ember under Background App Activity. Approve its system notification, then click Enable again."
                SMAppService.openSystemSettingsLoginItems()
            } else {
                let failure = error as NSError
                message = "Helper registration failed (\(failure.domain) \(failure.code)). \(failure.localizedDescription) Try Enable again; use Repair helper if it persists."
            }
        }
    }
    func repair() {
        guard !maximumActive, !busy else { message = "Return fans to Auto before repairing the helper."; return }
        shutdown()
        service.unregister { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error, (error as NSError).code != Int(kSMErrorJobNotFound) {
                    self.message = "Unable to unregister the old helper: \(error.localizedDescription)"; return
                }
                self.serviceStatus = self.service.status
                self.enable()
            }
        }
    }
    func connect() {
        serviceStatus = service.status
        guard installed else { enable(); return }
        guard !conflictingController else { message = "Quit Macs Fan Control before giving Ember control."; return }
        guard connection == nil else { evaluate(); return }
        let client = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/EmberFanClient")
        guard Self.validatedRequirement(app: Bundle.main.bundleURL, helper: client) != nil else {
            message = "Fan client signature is invalid. Reinstall a verified Ember build."; return
        }
        do { connection = try FanClientTransport(executable: client) }
        catch { message = "Unable to start the fan client."; return }
        // A successful round trip proves the service is available; registration alone does not.
        send(false)
    }
    func cycle() {
        if !connected { connect(); return }
        setMode(mode.next)
    }
    func setMode(_ newMode: FanMode) {
        guard newMode == .automatic || !conflictingController else {
            message = "Quit Macs Fan Control before giving Ember control."; return
        }
        guard connected else { message = "Enable and connect the fan helper first."; return }
        mode = newMode; evaluate()
    }
    func update(temperature: Double?, paused: Bool) {
        lastTemperature = temperature; lastSample = Date(); self.paused = paused; evaluate()
    }
    func sleep() { asleep = true; if connected { send(false) } }
    func wake() { asleep = false; lastSample = nil; if connected { send(false) } }
    func shutdown() {
        // Invalidating also makes the helper restore independently if the reply cannot arrive.
        connection?.invalidate(); connection = nil
    }
    func remove() {
        mode = .automatic
        guard connected else { unregister(); return }
        send(false, removeAfter: true)
    }
    private func unregister() {
        do { try service.unregister(); serviceStatus = service.status; shutdown(); message = "Fan helper removed" }
        catch { message = error.localizedDescription }
    }
    private func evaluate() {
        guard connected, !busy else { return }
        if mode == .automatic && !maximumActive { return }
        let stale = lastSample.map { Date().timeIntervalSince($0) > 45 } ?? true
        let shouldMax = policy.evaluate(mode: mode, temperature: stale ? nil : lastTemperature, threshold: threshold,
                                        paused: paused || asleep || stale || conflictingController)
        send(shouldMax)
    }
    private func send(_ maximum: Bool, removeAfter: Bool = false) {
        guard !busy, let connection else { return }
        busy = true
        let id = UUID(); requestID = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.requestID == id else { return }
            self.message = "Fan helper did not respond. Releasing control to its watchdog."
            self.connection?.invalidate(); self.disconnected()
        }
        timeout?.cancel(); timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
        connection.send(maximum) { [weak self] code, confirmed in
            Task { @MainActor in
                guard let self, self.requestID == id else { return }
                self.timeout?.cancel(); self.busy = false
                if code == ENOTCONN || code == EPROTO || code == ETIMEDOUT {
                    self.connection?.invalidate(); self.connection = nil
                    self.connected = false; self.maximumActive = false; self.mode = .automatic
                    self.message = "Fan helper is unavailable. Use Repair helper in Settings."
                    return
                }
                self.connected = true; self.maximumActive = confirmed
                if code == 0 {
                    self.message = confirmed ? "All fans at firmware maximum" : self.mode == .threshold ? "Auto until peak reaches \(Int(self.threshold))°C" : "macOS manages your fans"
                    if removeAfter { self.unregister() }
                } else {
                    self.mode = .automatic
                    self.message = code == EBUSY ? "Another fan controller owns the fans. Return it to Auto and quit it." : "Hardware refused fan control (\(code)). macOS control requested."
                }
            }
        }
    }
    private func disconnected() {
        timeout?.cancel(); connected = false; busy = false; maximumActive = false; mode = .automatic
        connection = nil; serviceStatus = service.status
        message = "Fan helper disconnected; automatic restoration requested."
    }
    private static func validatedRequirement(app: URL, helper: URL) -> String? {
        var bundleCode: SecStaticCode?, code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &bundleCode) == errSecSuccess,
              let bundleCode, SecStaticCodeCheckValidity(bundleCode, flags, nil) == errSecSuccess,
              SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { return nil }
        var requirement: SecRequirement?, text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement, SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }
}

private final class FanClientTransport: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "app.ember.fan-client")
    init(executable: URL) throws {
        process.executableURL = executable
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    func send(_ maximum: Bool, completion: @escaping @Sendable (Int32, Bool) -> Void) {
        queue.async {
            do {
                try self.input.fileHandleForWriting.write(contentsOf: Data((maximum ? "max\n" : "auto\n").utf8))
                var line = Data()
                while line.count < 64 {
                    guard let data = try self.output.fileHandleForReading.read(upToCount: 1), !data.isEmpty else { completion(ENOTCONN, false); return }
                    if data[0] == 10 { break }
                    line.append(data)
                }
                let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
                guard parts.count == 2, let code = Int32(parts[0]), parts[1] == "0" || parts[1] == "1" else { completion(EPROTO, false); return }
                completion(code, parts[1] == "1")
            } catch { completion(ENOTCONN, false) }
        }
    }
    func invalidate() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    deinit { invalidate() }
}
