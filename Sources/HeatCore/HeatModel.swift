import Foundation

public enum HeatLevel: String, CaseIterable, Sendable {
    case unknown, cool, warm, hot
    public var title: String { rawValue.capitalized }
    public var message: String {
        switch self {
        case .unknown: "Reading your Mac"
        case .cool: "A little work. Plenty of headroom."
        case .warm: "Your Mac is working a little harder."
        case .hot: "Time to give your Mac some breathing room."
        }
    }
    public static func classify(temperature: Double?, pressure: Int, previous: HeatLevel) -> HeatLevel {
        if pressure >= 2 { return .hot }
        guard let t = temperature, t.isFinite else { return pressure == 1 ? .warm : .unknown }
        if t >= 85 || (previous == .hot && t >= 80) { return .hot }
        if pressure == 1 || t >= 65 || (previous == .warm && t >= 60) { return .warm }
        return .cool
    }
}

public struct ProcessIdentity: Hashable, Sendable, Codable {
    public let pid: Int32
    public let seconds: UInt64
    public let microseconds: UInt64
    public init(pid: Int32, seconds: UInt64, microseconds: UInt64) {
        self.pid = pid; self.seconds = seconds; self.microseconds = microseconds
    }
}

public struct ProcessReading: Sendable {
    public var identity: ProcessIdentity
    public var parentPID: Int32
    public var uid: UInt32
    public var name: String
    public var path: String
    public var cpuTime: UInt64
    public var memory: UInt64
    public init(identity: ProcessIdentity, parentPID: Int32 = 1, uid: UInt32 = 0, name: String, path: String = "", cpuTime: UInt64, memory: UInt64 = 0) {
        self.identity = identity; self.parentPID = parentPID; self.uid = uid; self.name = name
        self.path = path; self.cpuTime = cpuTime; self.memory = memory
    }
    public var appPath: String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

public struct ProcessActivity: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var appPath: String?
    public var members: [ProcessReading]
    public var cpu: Double
    public var share: Double
    public var memory: UInt64
    public var background: Bool
    public var sustainedSeconds: Double
    public var anomaly: String? {
        guard sustainedSeconds >= 30 else { return nil }
        if background && cpu >= 20 { return "Sustained background CPU · \(Int(sustainedSeconds))s" }
        if cpu >= 100 { return "Sustained high CPU · \(Int(sustainedSeconds))s" }
        return nil
    }
}

public struct ActivityTracker: Sendable {
    private struct AppMetadata: Sendable {
        let path: String?
        let name: String?
        init(executable: String) {
            if let range = executable.range(of: ".app/") {
                let app = String(executable[..<range.lowerBound]) + ".app"
                path = app; name = URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
            } else { path = nil; name = nil }
        }
    }
    private var previous: [ProcessIdentity: UInt64] = [:]
    private var previousTime: Double?
    private var sustained: [String: Double] = [:]
    private var appMetadata: [String: AppMetadata] = [:]
    public init() {}
    public mutating func reset() { previous = [:]; previousTime = nil; sustained = [:]; appMetadata = [:] }
    public mutating func sample(_ readings: [ProcessReading], at time: Double, foregroundPath: String?) -> [ProcessActivity] {
        defer {
            var counters: [ProcessIdentity: UInt64] = [:]
            counters.reserveCapacity(readings.count)
            for reading in readings { counters[reading.identity] = reading.cpuTime }
            previous = counters
            previousTime = time
        }
        guard let last = previousTime, time > last, time - last <= PollingCycle.maximumSampleGap else {
            sustained = [:]; appMetadata = [:]; return []
        }
        let elapsed = time - last
        var byPID: [Int32: ProcessReading] = [:]
        byPID.reserveCapacity(readings.count)
        var metadata: [String: AppMetadata] = [:]
        for reading in readings {
            byPID[reading.identity.pid] = reading
            if metadata[reading.path] == nil {
                metadata[reading.path] = appMetadata[reading.path] ?? AppMetadata(executable: reading.path)
            }
        }
        // Retain only paths in this sample. Exec and reparenting use fresh paths
        // and ancestry; exited applications cannot grow the cache indefinitely.
        appMetadata = metadata
        var groups: [String: ProcessActivity] = [:]
        for reading in readings {
            guard let old = previous[reading.identity], reading.cpuTime >= old else { continue }
            let cpu = Double(reading.cpuTime - old) / 1_000_000_000 / elapsed * 100
            // Attribute helpers spawned outside an app bundle to the nearest app ancestor.
            var info = metadata[reading.path]!
            if info.path == nil && reading.parentPID > 1 {
                var parent = reading.parentPID
                var visited: Set<Int32> = [reading.identity.pid]
                while info.path == nil, parent > 1, visited.insert(parent).inserted, let ancestor = byPID[parent] {
                    info = metadata[ancestor.path]!; parent = ancestor.parentPID
                }
            }
            let app = info.path
            let id = app ?? "pid:\(reading.identity.pid):\(reading.identity.seconds):\(reading.identity.microseconds)"
            groups[id, default: ProcessActivity(
                id: id,
                name: info.name ?? reading.name,
                appPath: app, members: [], cpu: 0, share: 0, memory: 0,
                background: app == nil || app != foregroundPath, sustainedSeconds: 0
            )].include(reading, cpu: cpu)
        }
        let total = groups.values.reduce(0) { $0 + $1.cpu }
        var nextSustained: [String: Double] = [:]
        let result = groups.values.map { entry in
            var g = entry
            g.share = total > 0.5 ? g.cpu / total * 100 : 0
            let high = (g.background && g.cpu >= 20) || g.cpu >= 100
            g.sustainedSeconds = high ? (sustained[g.id] ?? 0) + elapsed : 0
            if high { nextSustained[g.id] = g.sustainedSeconds }
            return g
        }.sorted { $0.cpu > $1.cpu }
        sustained = nextSustained
        return result
    }
}

private extension ProcessActivity {
    mutating func include(_ reading: ProcessReading, cpu amount: Double) {
        members.append(reading); cpu += amount; memory += reading.memory
    }
}

public struct SensorValue: Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var value: Double
    public init(key: String, value: Double) { self.key = key; self.value = value }
}
public struct SensorSnapshot: Sendable {
    public var cpu: [SensorValue] = []
    public var gpu: [SensorValue] = []
    public var soc: [SensorValue] = []
    public var battery: [SensorValue] = []
    public var fans: [SensorValue] = []
    public var fanCount: Int? = nil
    public var connected = false
    public init() {}
    public var cpuAverage: Double? { cpu.isEmpty ? nil : cpu.map(\.value).reduce(0, +) / Double(cpu.count) }
    public var cpuTemperature: Double? { cpu.map(\.value).max() }
    public var gpuTemperature: Double? { gpu.map(\.value).max() }
    public var batteryTemperature: Double? { battery.map(\.value).max() }
    public var hottest: Double? { (cpu + gpu + soc).map(\.value).max() }
    public var fansSpinning: Bool { fans.contains { $0.value > 500 } }
}
