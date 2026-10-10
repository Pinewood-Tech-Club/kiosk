import Foundation

@MainActor
final class FrameStats {
    struct Summary {
        var fps: Double = 0
        var p50: Double = 0
        var p99: Double = 0
        var max: Double = 0
        var cpuP99: Double = 0
        var cpuMax: Double = 0
        var samples = 0
    }

    private var frameTimes = [Double](repeating: 0, count: 480)
    private var cpuTimes = [Double](repeating: 0, count: 480)
    private var index = 0
    private var count = 0

    func record(frame: Double, cpu: Double) {
        frameTimes[index] = frame
        cpuTimes[index] = cpu
        index = (index + 1) % frameTimes.count
        count = min(count + 1, frameTimes.count)
    }

    func reset() {
        index = 0
        count = 0
    }

    func summary() -> Summary {
        guard count > 0 else { return Summary() }
        let frames = Array(frameTimes.prefix(count)).sorted()
        let cpu = Array(cpuTimes.prefix(count)).sorted()
        func percentile(_ values: [Double], _ p: Double) -> Double {
            values[min(values.count - 1, Int(Double(values.count - 1) * p + 0.5))]
        }
        let mean = frames.reduce(0, +) / Double(frames.count)
        return Summary(fps: mean > 0 ? 1 / mean : 0,
                       p50: percentile(frames, 0.5),
                       p99: percentile(frames, 0.99),
                       max: frames.last ?? 0,
                       cpuP99: percentile(cpu, 0.99),
                       cpuMax: cpu.last ?? 0,
                       samples: count)
    }
}
