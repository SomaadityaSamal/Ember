import Testing
import Foundation
import HeatCore
import TelemetryBridge

@Suite struct HeatCoreTests {
    @Test func temperatureThresholdsAndHysteresis() {
        #expect(HeatLevel.classify(temperature: 64, pressure: 0, previous: .cool) == .cool)
        #expect(HeatLevel.classify(temperature: 65, pressure: 0, previous: .cool) == .warm)
        #expect(HeatLevel.classify(temperature: 62, pressure: 0, previous: .warm) == .warm)
        #expect(HeatLevel.classify(temperature: 59, pressure: 0, previous: .warm) == .cool)
        #expect(HeatLevel.classify(temperature: 85, pressure: 0, previous: .cool) == .hot)
        #expect(HeatLevel.classify(temperature: 82, pressure: 0, previous: .hot) == .hot)
        #expect(HeatLevel.classify(temperature: 79, pressure: 0, previous: .hot) == .warm)
        #expect(HeatLevel.classify(temperature: nil, pressure: 0, previous: .cool) == .unknown)
        #expect(HeatLevel.classify(temperature: .nan, pressure: 0, previous: .cool) == .unknown)
        #expect(HeatLevel.classify(temperature: 40, pressure: 2, previous: .cool) == .hot)
        #expect(HeatLevel.classify(temperature: nil, pressure: 1, previous: .cool) == .warm)
    }
    func row(_ pid: Int32, _ seconds: UInt64 = 1, cpu: UInt64, path: String = "/Applications/Browser.app/Contents/MacOS/Browser", parent: Int32 = 1) -> ProcessReading {
        .init(identity: .init(pid: pid, seconds: seconds, microseconds: 0), parentPID: parent, name: "Process", path: path, cpuTime: cpu, memory: 100)
    }
    @Test func groupedCPUTimeAndRelativeShare() throws {
        var tracker = ActivityTracker()
        let initial = [row(10, cpu: 0), row(11, cpu: 0, path: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"), row(12, cpu: 0, path: "/usr/bin/worker")]
        #expect(tracker.sample(initial, at: 1, foregroundPath: nil).isEmpty)
        let next = [row(10, cpu: 2_000_000_000), row(11, cpu: 1_000_000_000, path: initial[1].path), row(12, cpu: 1_000_000_000, path: initial[2].path)]
        let result = tracker.sample(next, at: 3, foregroundPath: "/Applications/Browser.app")
        let browser = try #require(result.first)
        #expect(browser.members.count == 2)
        #expect(browser.cpu == 150)
        #expect(browser.share == 75)
        #expect(browser.memory == 200)
        #expect(!browser.background)
        #expect(result.reduce(0) { $0 + $1.share } == 100)
    }
    @Test func helperInheritsAncestorApp() throws {
        var tracker = ActivityTracker()
        _ = tracker.sample([row(10, cpu: 0), row(11, cpu: 0, path: "/usr/bin/helper", parent: 10)], at: 1, foregroundPath: nil)
        let result = tracker.sample([row(10, cpu: 0), row(11, cpu: 1_000_000_000, path: "/usr/bin/helper", parent: 10)], at: 2, foregroundPath: nil)
        #expect(result.count == 1)
        #expect(try #require(result.first).members.count == 2)
    }
    @Test func pidReuseAndCounterResetDoNotCreateSpikes() {
        var tracker = ActivityTracker()
        _ = tracker.sample([row(10, cpu: 9_000_000_000)], at: 1, foregroundPath: nil)
        #expect(tracker.sample([row(10, 2, cpu: 30_000_000_000)], at: 2, foregroundPath: nil).isEmpty)
        #expect(tracker.sample([row(10, 2, cpu: 0)], at: 3, foregroundPath: nil).isEmpty)
        let result = tracker.sample([row(10, 2, cpu: 100)], at: 4, foregroundPath: nil)
        #expect(result.first?.share == 0)
    }
    @Test func sustainedBackgroundActivityAndRecovery() throws {
        var tracker = ActivityTracker()
        _ = tracker.sample([row(10, cpu: 0)], at: 0, foregroundPath: nil)
        var latest: ProcessActivity?
        for second in stride(from: 3, through: 33, by: 3) {
            latest = tracker.sample([row(10, cpu: UInt64(second) * 300_000_000)], at: Double(second), foregroundPath: nil).first
            if second < 30 { #expect(latest?.anomaly == nil) }
        }
        #expect(try #require(latest).anomaly != nil)
        let recovered = tracker.sample([row(10, cpu: 9_900_000_000)], at: 36, foregroundPath: nil)
        #expect(recovered.first?.anomaly == nil)
        #expect(tracker.sample([row(10, cpu: 90_000_000_000)], at: 136, foregroundPath: nil).isEmpty)
    }

    @Test func liveCPUCountersUseNanoseconds() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "while :; do :; done"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        func cpuTime() throws -> UInt64 {
            var pointer: UnsafeMutablePointer<EmberProcess>?
            var total: Int32 = 0
            let count = ember_processes(&pointer, &total)
            defer { ember_free_processes(pointer) }
            let rows = try #require(pointer)
            return try #require((0..<Int(count)).map { rows[$0] }.first { $0.pid == child.processIdentifier }).cpu_nanoseconds
        }
        Thread.sleep(forTimeInterval: 0.1)
        let start = ProcessInfo.processInfo.systemUptime
        let initial = try cpuTime()
        Thread.sleep(forTimeInterval: 0.5)
        let final = try cpuTime()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let cpu = Double(final - initial) / 1_000_000_000 / elapsed * 100
        // A single busy core should be near 100%, not the ~2.4% that results
        // from treating Apple Silicon's 24MHz Mach ticks as nanoseconds.
        #expect(cpu > 30)
        #expect(cpu < 140)
    }
    @Test func safeSignalRejectsSelfAndStaleIdentity() throws {
        #expect(ember_signal(1, 0, 0, true) == EPERM)
        #expect(ember_signal(getpid(), 0, 0, true) == EPERM)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        #expect(ember_signal(child.processIdentifier, 0, 0, true) == ESRCH)
        #expect(child.isRunning)
        var raw: UnsafeMutablePointer<EmberProcess>?
        var total: Int32 = 0
        let count = ember_processes(&raw, &total)
        defer { ember_free_processes(raw) }
        let rows = try #require(raw)
        let identity = try #require((0..<Int(count)).map { rows[$0] }.first { $0.pid == child.processIdentifier })
        #expect(ember_signal(identity.pid, identity.start_seconds, identity.start_microseconds, true) == 0)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
    }
}

@Suite struct PreferencesAndFanTests {
    @Test func longPollingCyclesProduceActivity() throws {
        for cycle in PollingCycle.choices {
            var tracker = ActivityTracker()
            let identity = ProcessIdentity(pid: 10, seconds: 1, microseconds: 0)
            _ = tracker.sample([.init(identity: identity, name: "worker", cpuTime: 0)], at: 1, foregroundPath: nil)
            let result = tracker.sample([.init(identity: identity, name: "worker", cpuTime: UInt64(cycle * 1_000_000_000))], at: 1 + cycle, foregroundPath: nil)
            #expect(try #require(result.first).cpu == 100)
        }
        #expect(PollingCycle.validated(3) == 5)
        #expect(PollingCycle.validated(15) == 15)
        #expect(PollingCycle.validated(.nan) == 5)
    }
    @Test func temperatureSourceUsesAverageOrExplicitPeak() {
        var sensors = SensorSnapshot()
        sensors.cpu = [.init(key: "A", value: 40), .init(key: "B", value: 80)]
        sensors.gpu = [.init(key: "G", value: 90)]
        sensors.soc = [.init(key: "S", value: 95)]
        #expect(TemperatureSource.cpuAverage.value(in: sensors) == 60)
        #expect(TemperatureSource.cpuPeak.value(in: sensors) == 80)
        #expect(TemperatureSource.systemPeak.value(in: sensors) == 95)
        #expect(TemperatureSource.individual.value(in: sensors, key: "G") == 90)
        #expect(TemperatureSource.individual.value(in: sensors, key: "missing") == nil)
        #expect(SensorSnapshot().cpuAverage == nil)
        #expect(SensorProfile.cpuKeys(brand: "Unknown chip").isEmpty)
        #expect(SensorProfile.cpuKeys(brand: "Apple M4").count == 12)
    }
    @Test func thresholdHysteresisAndFailsafe() {
        var policy = FanPolicy()
        let outcomes = [
            policy.evaluate(mode: .threshold, temperature: 79, threshold: 80, paused: false),
            policy.evaluate(mode: .threshold, temperature: 80, threshold: 80, paused: false),
            policy.evaluate(mode: .threshold, temperature: 77, threshold: 80, paused: false),
            policy.evaluate(mode: .threshold, temperature: 75, threshold: 80, paused: false),
            policy.evaluate(mode: .threshold, temperature: nil, threshold: 80, paused: false),
            policy.evaluate(mode: .threshold, temperature: .nan, threshold: 80, paused: false),
            policy.evaluate(mode: .threshold, temperature: 90, threshold: 0, paused: false),
            policy.evaluate(mode: .maximum, temperature: 40, threshold: 80, paused: false),
            policy.evaluate(mode: .maximum, temperature: 90, threshold: 80, paused: true),
            policy.evaluate(mode: .automatic, temperature: 100, threshold: 80, paused: false)
        ]
        #expect(outcomes == [false, true, true, false, false, false, false, true, false, false])
        #expect(FanSettings.threshold(.nan) == 80)
        #expect(FanMode.automatic.next == .maximum)
        #expect(FanMode.maximum.next == .threshold)
        #expect(FanMode.threshold.next == .automatic)
    }
    @Test func privilegedHardwareAPIRejectsUnprivilegedCaller() {
        if geteuid() != 0 { #expect(ember_fans_max(0) == EPERM) }
        #expect(ember_fans_restore(0) == 0)
        #expect(!ember_fans_verify_max(0))
    }
}
