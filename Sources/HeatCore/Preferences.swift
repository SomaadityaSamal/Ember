import Foundation

public enum PollingCycle {
    public static let choices: [Double] = [5, 15, 30]
    public static func validated(_ value: Double) -> Double { choices.contains(value) ? value : 5 }
    // Allow a delayed 30-second poll, while treating long gaps as a new baseline.
    public static let maximumSampleGap: Double = 90
}

public enum TemperatureSource: String, CaseIterable, Sendable {
    case cpuAverage = "CPU average"
    case cpuPeak = "Hottest CPU core"
    case systemPeak = "Hottest CPU / GPU / SoC"
    case individual = "Individual sensor"
    public func value(in snapshot: SensorSnapshot, key: String = "") -> Double? {
        switch self {
        case .cpuAverage: snapshot.cpuAverage
        case .cpuPeak: snapshot.cpuTemperature
        case .systemPeak: snapshot.hottest
        case .individual: (snapshot.cpu + snapshot.gpu + snapshot.soc + snapshot.battery).first { $0.key == key }?.value
        }
    }
}

public enum SensorProfile {
    public static func cpuKeys(brand: String) -> [String] {
        let brand = brand.lowercased()
        if brand.contains("m1") { return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"] }
        if brand.contains("m2") { return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"] }
        if brand.contains("m3") { return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"] }
        if brand.contains("m4") { return ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"] }
        if brand.contains("m5") { return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"] }
        if brand.contains("intel") { return ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H", "TCAD"] }
        return [] // Never invent CPU-core mappings for unknown chips.
    }
}

public enum FanMode: Int, CaseIterable, Sendable {
    case automatic, maximum, threshold
    public var title: String { switch self { case .automatic: "Auto"; case .maximum: "Max"; case .threshold: "Temperature" } }
    public var next: FanMode { FanMode(rawValue: (rawValue + 1) % 3)! }
}
public enum FanSettings {
    public static func threshold(_ value: Double) -> Double { value.isFinite ? min(100, max(45, value)) : 80 }
}

public struct FanPolicy: Sendable {
    public private(set) var maximumActive = false
    public init() {}
    public mutating func evaluate(mode: FanMode, temperature: Double?, threshold: Double, paused: Bool) -> Bool {
        guard !paused else { maximumActive = false; return false }
        switch mode {
        case .automatic: maximumActive = false
        case .maximum: maximumActive = true
        case .threshold:
            guard let t = temperature, t.isFinite, threshold.isFinite, (45...100).contains(threshold) else { maximumActive = false; return false }
            maximumActive = t >= threshold || (maximumActive && t > threshold - 5)
        }
        return maximumActive
    }
}
