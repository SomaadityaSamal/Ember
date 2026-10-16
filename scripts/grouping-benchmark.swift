import Foundation
import Darwin

// Synthetic names and paths only. This benchmark never samples the user's apps.
@main enum GroupingBenchmark {
    static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func main() {
        for (label, count, samples) in [("1000-processes", 1000, 100), ("2000-processes", 2000, 30)] {
            var readings = (0..<count).map { index in
                ProcessReading(identity: .init(pid: Int32(index + 10), seconds: 1, microseconds: 0),
                               name: "worker", path: index < count * 3 / 4 ? "/Applications/Browser.app/Contents/MacOS/worker" : "/usr/bin/worker",
                               cpuTime: 0, memory: 1024)
            }
            var times: [Double] = []
            for _ in 0..<3 {
                var tracker = ActivityTracker()
                _ = tracker.sample(readings, at: 1, foregroundPath: nil)
                let start = cpuSeconds()
                for iteration in 1...samples {
                    for index in readings.indices { readings[index].cpuTime += 1_000_000 }
                    let result = tracker.sample(readings, at: Double(iteration + 1), foregroundPath: nil)
                    precondition(result.reduce(0) { $0 + $1.members.count } == count)
                    precondition(abs(result.reduce(0) { $0 + $1.cpu } - Double(count) * 0.1) < 0.001)
                }
                times.append((cpuSeconds() - start) / Double(samples) * 1000)
            }
            print("\(label): median \(String(format: "%.3f", times.sorted()[1])) CPU ms/sample; \(count) processes")
        }
    }
}
