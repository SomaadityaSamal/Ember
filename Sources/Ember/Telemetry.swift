import AppKit
import Combine
import HeatCore
import TelemetryBridge

final class TelemetryReader: @unchecked Sendable {
    // All mutable sampling state is confined to Monitor's serial queue.
    private var connection: UInt32 = 0
    private var tracker = ActivityTracker()
    private var sensorKeys: (cpu: [String], gpu: [String], battery: [String])?
    private var reads = 0
    private let brand: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
    deinit { ember_smc_close(connection) }

    func processes(at time: Double, foreground: String?) -> (activities: [ProcessActivity], readable: Int, total: Int) {
        var pointer: UnsafeMutablePointer<EmberProcess>?
        var total: Int32 = 0
        let count = ember_processes(&pointer, &total)
        defer { ember_free_processes(pointer) }
        guard let pointer else { return ([], 0, Int(total)) }
        var rows: [ProcessReading] = []
        for i in 0..<Int(count) {
            var raw = pointer[i]
            let name = withUnsafePointer(to: &raw.name) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
            let path = withUnsafePointer(to: &raw.path) { $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) } }
            rows.append(ProcessReading(identity: .init(pid: raw.pid, seconds: raw.start_seconds, microseconds: raw.start_microseconds),
                                       parentPID: raw.parent_pid, uid: raw.uid, name: name, path: path,
                                       cpuTime: raw.cpu_nanoseconds, memory: raw.resident_bytes))
        }
        return (tracker.sample(rows, at: time, foregroundPath: foreground), Int(count), Int(total))
    }

    func sensors() -> SensorSnapshot {
        reads += 1
        if connection == 0 { connection = ember_smc_open() }
        var snapshot = SensorSnapshot()
        snapshot.connected = connection != 0
        guard connection != 0 else { return snapshot }
        // Probe supported keys once, then only read sensors present on this machine.
        // Retry discovery periodically to recover unavailable sensors after sleep.
        if sensorKeys == nil || reads % 120 == 0 {
            let cpu = SensorProfile.cpuKeys(brand: brand)
            let gpu = ["TG0D", "TG0P"] + (0..<256).map { "Tg" + String(format: "%02X", $0) } +
                ["Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0U", "Tg0X", "Tg1U", "Tg1Y", "Tg0d", "Tg0e", "Tg0f", "Tg0g", "Tg0j", "Tg0k", "Tg1k", "Tg1c", "Tg1g"]
            let battery = ["TB0T", "TB1T", "TB2T"]
            sensorKeys = (validKeys(cpu), validKeys(gpu), validKeys(battery))
        }
        if let keys = sensorKeys {
            snapshot.cpu = temperatures(keys.cpu)
            snapshot.gpu = temperatures(keys.gpu)
            snapshot.battery = temperatures(keys.battery)
        }
        snapshot.soc = temperatures(["TCMz"])
        if let count = read("FNum"), count >= 0, count <= 10 {
            snapshot.fanCount = Int(count)
            snapshot.fans = (0..<Int(count)).compactMap { i in
                let key = "F\(i)Ac"
                guard let value = read(key), value >= 0, value < 30000 else { return nil }
                return SensorValue(key: key, value: value)
            }
        }
        return snapshot
    }
    private func read(_ key: String) -> Double? {
        var value = 0.0
        return key.withCString { ember_smc_read(connection, $0, &value) } ? value : nil
    }
    private func validKeys(_ keys: [String]) -> [String] {
        Array(Set(keys)).sorted().filter { read($0) != nil }
    }
    private func temperatures(_ keys: [String]) -> [SensorValue] {
        keys.compactMap { key in
            guard let v = read(key), v >= 5, v < 130 else { return nil }
            return SensorValue(key: key, value: v)
        }
    }
}

struct HistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let temperature: Double?
    let cpu: Double
}

@MainActor final class Monitor: ObservableObject {
    @Published var sensors = SensorSnapshot()
    @Published var activities: [ProcessActivity] = []
    @Published var history: [HistoryPoint] = []
    @Published var level = HeatLevel.unknown
    @Published var pressure = 0
    @Published var readable = 0
    @Published var total = 0
    @Published var lastUpdate: Date?
    @Published var sampling = true
    @Published var panelVisible = false
    @Published var showSettings = false
    @Published var showSensors = false
    @Published var search = ""
    @Published var filter: ActivityFilter = .all
    @Published var interval: Double = PollingCycle.validated(UserDefaults.standard.double(forKey: "sampleInterval")) {
        didSet {
            let validated = PollingCycle.validated(interval)
            if validated != interval { interval = validated; return }
            UserDefaults.standard.set(interval, forKey: "sampleInterval"); restart()
        }
    }
    @Published var showCulprit = UserDefaults.standard.object(forKey: "showCulprit") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCulprit, forKey: "showCulprit") }
    }
    @Published var animate = UserDefaults.standard.object(forKey: "animate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(animate, forKey: "animate") }
    }
    @Published var temperatureSource = TemperatureSource(rawValue: UserDefaults.standard.string(forKey: "temperatureSource") ?? "") ?? .cpuAverage {
        didSet { UserDefaults.standard.set(temperatureSource.rawValue, forKey: "temperatureSource"); onUpdate?() }
    }
    @Published var sensorKey = UserDefaults.standard.string(forKey: "sensorKey") ?? "" {
        didSet { UserDefaults.standard.set(sensorKey, forKey: "sensorKey"); onUpdate?() }
    }
    var displayTemperature: Double? { temperatureSource.value(in: sensors, key: sensorKey) }
    var temperatureLabel: String { temperatureSource == .individual ? "Sensor \(sensorKey)" : temperatureSource.rawValue }
    let fans = FanController()
    private var fanSubscription: AnyCancellable?
    private let reader = TelemetryReader()
    private let queue = DispatchQueue(label: "app.ember.telemetry", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var lastExternalForeground: String?
    var onUpdate: (() -> Void)?
    var top: ProcessActivity? { activities.first { $0.cpu >= 1 } }
    var anomalies: [ProcessActivity] { activities.filter { $0.anomaly != nil } }
    var totalCPU: Double { activities.reduce(0) { $0 + $1.cpu } / Double(ProcessInfo.processInfo.activeProcessorCount) }
    var pressureLabel: String { ["Nominal", "Fair", "Serious", "Critical"][min(3, max(0, pressure))] }
    var filtered: [ProcessActivity] {
        activities.filter { activity in
            (search.isEmpty || activity.name.localizedCaseInsensitiveContains(search) || activity.members.contains { String($0.identity.pid).contains(search) }) &&
            (filter == .all || (filter == .apps && activity.appPath != nil) || (filter == .background && activity.background))
        }
    }
    init() {
        fanSubscription = fans.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.onUpdate?()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fans.sleep() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fans.wake(); self?.refresh() }
        }
        restart()
    }
    func restart() {
        timer?.invalidate()
        guard sampling else { onUpdate?(); return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func togglePause() { sampling.toggle(); fans.update(temperature: sensors.hottest, paused: !sampling); restart() }
    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            lastExternalForeground = front.bundleURL?.path
        }
        let foreground = lastExternalForeground
        let reader = reader
        queue.async { [weak self] in
            let s = reader.sensors()
            let result = reader.processes(at: ProcessInfo.processInfo.systemUptime, foreground: foreground)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sensors = s; self.activities = result.activities
                self.readable = result.readable; self.total = result.total
                self.pressure = ProcessInfo.processInfo.thermalState.rawValue
                self.level = HeatLevel.classify(temperature: s.hottest, pressure: self.pressure, previous: self.level)
                self.lastUpdate = Date()
                self.fans.update(temperature: s.hottest, paused: !self.sampling)
                self.history.append(.init(date: Date(), temperature: s.hottest, cpu: self.totalCPU))
                self.history.removeAll { $0.date < Date().addingTimeInterval(-300) }
                self.inFlight = false
                self.onUpdate?()
            }
        }
    }
    func canTerminate(_ activity: ProcessActivity) -> Bool {
        activity.members.contains { row in
            row.uid == getuid() && row.identity.pid > 1 && row.identity.pid != getpid() &&
            !row.path.isEmpty && !row.path.hasPrefix("/System/Library/") &&
            !row.path.hasPrefix("/usr/libexec/") && !row.path.hasPrefix("/sbin/")
        }
    }
    func terminate(_ activity: ProcessActivity, force: Bool) {
        let alert = NSAlert()
        alert.messageText = "\(force ? "Force quit" : "Quit") \(activity.name)?"
        alert.informativeText = force ? "Unsaved changes may be lost. Ember will end the \(activity.members.count) sampled processes in this group that you own and are allowed to stop." : "A termination request will be sent to the sampled processes in this group."
        alert.alertStyle = .warning
        alert.addButton(withTitle: force ? "Force Quit" : "Quit App")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var errors: [String] = []
        for row in activity.members {
            let code = ember_signal(row.identity.pid, row.identity.seconds, row.identity.microseconds, force)
            if code != 0 && code != ESRCH { errors.append("PID \(row.identity.pid): \(String(cString: strerror(code)))") }
        }
        if !errors.isEmpty {
            let failure = NSAlert(); failure.messageText = "Some processes could not be stopped"
            failure.informativeText = errors.joined(separator: "\n"); failure.runModal()
        }
        refresh()
    }
}

enum ActivityFilter: String, CaseIterable { case all = "All activity", apps = "Apps", background = "Background" }
