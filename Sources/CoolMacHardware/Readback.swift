import Foundation
import Darwin

public enum Readback {
    public static func confirmStable(
        target: Double,
        duration: Double = 1,
        now: () -> Double = { ContinuousClock.now },
        pause: () -> Void = { usleep(50_000) },
        read: () throws -> Double
    ) throws {
        let deadline = now() + duration
        while true {
            let actual = try read()
            guard actual.isFinite, actual == target else { throw HardwareError("持续确认失败（请求 \(target)，实际 \(actual)）") }
            if now() >= deadline { return }
            pause()
        }
    }

    /// A bounded wait for hardware acknowledgement, never a repeated write.
    @discardableResult
    public static func verify(
        target: Double,
        timeout: Double = 0.4,
        tolerance: Double = 1,
        now: () -> Double = { ContinuousClock.now },
        pause: () -> Void = { usleep(20_000) },
        read: () throws -> Double
    ) throws -> Double {
        let deadline = now() + timeout
        var actual = try read()
        while true {
            guard actual.isFinite else { throw HardwareError("写入回读为无效值") }
            if abs(actual - target) <= tolerance { return actual }
            guard now() < deadline else { throw HardwareError("写入后 \(Int(timeout * 1000))ms 内回读未确认（请求 \(target)，实际 \(actual)）") }
            pause()
            actual = try read()
        }
    }
}
