import Testing
@testable import CoolMacCore

private func fan(
    id: Int = 0,
    actual: Double = 2_000,
    minimum: Double = 2_000,
    maximum: Double = 6_000,
    target: Double = 2_000,
    manual: Bool = false
) -> FanReading {
    FanReading(id: id, actualRPM: actual, minimumRPM: minimum, maximumRPM: maximum, targetRPM: target, manual: manual)
}

private func temperatures(cpu: Double = 50, gpu: Double = 49) -> [TemperatureReading] {
    [
        TemperatureReading(key: "test-cpu", name: "CPU", celsius: cpu, group: "cpu"),
        TemperatureReading(key: "test-gpu", name: "GPU", celsius: gpu, group: "gpu"),
    ]
}

private func snapshot(
    cpu: Double = 50,
    gpu: Double = 49,
    readings: [TemperatureReading]? = nil,
    fans: [FanReading] = [fan()],
    pressure: Int = 0,
    supported: Bool = true,
    issues: [String] = [],
    sampledAt: Double = 1_700_000_000
) -> HardwareSnapshot {
    HardwareSnapshot(
        sampledAt: sampledAt, model: "Test Mac", temperatures: readings ?? temperatures(cpu: cpu, gpu: gpu),
        fans: fans, thermalPressure: pressure, supported: supported, issues: issues
    )
}

private let invalidFans: [FanReading] = [
    fan(id: -1),
    fan(actual: -1),
    fan(actual: .nan),
    fan(actual: .infinity),
    fan(actual: -.infinity),
    fan(actual: 6_001),
    fan(minimum: 0),
    fan(minimum: -1),
    fan(minimum: .nan),
    fan(minimum: .infinity),
    fan(minimum: -.infinity),
    fan(maximum: 2_000),
    fan(maximum: 1_999),
    fan(maximum: .nan),
    fan(maximum: .infinity),
    fan(maximum: -.infinity),
    fan(target: -1),
    fan(target: .nan),
    fan(target: .infinity),
    fan(target: -.infinity),
    fan(target: 6_001),
]

struct FanPolicyTests {
    @Test func systemAlwaysRestoresEvenWhenAllInputsAreInvalid() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(), mode: .cool, now: 0, sampleAge: 0)
        let decision = policy.evaluate(
            snapshot: snapshot(readings: [], fans: [], pressure: -1, supported: false, issues: ["sample failed"], sampledAt: .nan),
            mode: .system, now: .nan, sampleAge: .infinity
        )
        #expect(decision.action == .system)
        #expect(decision.targets.isEmpty)
        #expect(!decision.reason.isEmpty)
    }

    @Test(arguments: [CoolingMode.cool, .boost])
    func invalidSnapshotFailsClosedInEveryControlledMode(mode: CoolingMode) {
        var policy = FanPolicy()
        let decision = policy.evaluate(snapshot: snapshot(supported: false), mode: mode, now: 0, sampleAge: 0)
        #expect(decision.action == .fault)
        #expect(decision.targets.isEmpty)
    }

    @Test(arguments: [-0.01, 3.000_001, Double.nan, .infinity, -.infinity])
    func invalidOrExpiredMonotonicAgeFaults(age: Double) {
        var policy = FanPolicy()
        let decision = policy.evaluate(snapshot: snapshot(), mode: .cool, now: 10, sampleAge: age)
        #expect(decision.action == .fault)
        #expect(decision.targets.isEmpty)
    }

    @Test(arguments: [-1.0, Double.nan, .infinity, -.infinity])
    func invalidMonotonicTimeFaults(now: Double) {
        var policy = FanPolicy()
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: now, sampleAge: 0).action == .fault)
    }

    @Test func monotonicClockMayRepeatButMustNotMoveBackwards() {
        var policy = FanPolicy()
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 10, sampleAge: 0).action == .targets)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 10, sampleAge: 0).action == .hold)
        let decision = policy.evaluate(snapshot: snapshot(), mode: .cool, now: 9.99, sampleAge: 0)
        #expect(decision.action == .fault)
        #expect(decision.reason.contains("倒退"))
        #expect(decision.targets.isEmpty)
    }

    @Test(arguments: [-1_000_000_000.0, 0.0, 9_000_000_000.0])
    func ageUsesOnlyInjectedSampleAgeNotSampleTimestamp(sampledAt: Double) {
        var policy = FanPolicy()
        let decision = policy.evaluate(snapshot: snapshot(sampledAt: sampledAt), mode: .cool, now: 1, sampleAge: 3)
        #expect(decision.action == .targets)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteTimestampMetadataFaults(sampledAt: Double) {
        var policy = FanPolicy()
        #expect(policy.evaluate(snapshot: snapshot(sampledAt: sampledAt), mode: .cool, now: 0, sampleAge: 0).action == .fault)
    }

    @Test(arguments: [-1, 4, Int.max])
    func pressureMustBeInModelRange(pressure: Int) {
        var policy = FanPolicy()
        #expect(policy.evaluate(snapshot: snapshot(pressure: pressure), mode: .cool, now: 0, sampleAge: 0).action == .fault)
    }

    @Test func hardwareIssuesRemainVisible() {
        var policy = FanPolicy()
        let decision = policy.evaluate(
            snapshot: snapshot(issues: ["read failed", "unknown type"]), mode: .cool, now: 0, sampleAge: 0
        )
        #expect(decision.action == .fault)
        #expect(decision.reason.contains("read failed"))
        #expect(decision.reason.contains("unknown type"))
    }

    @Test func bothRequiredGroupsMustExistAndUnknownGroupsAreNotAFallback() {
        let missingGroups: [[TemperatureReading]] = [
            [],
            [temperatures()[0]],
            [temperatures()[1]],
            [TemperatureReading(key: "other", name: "Other", celsius: 60, group: "other")],
            [TemperatureReading(key: "cpu", name: "CPU", celsius: 60, group: "CPU"), temperatures()[1]],
        ]
        for readings in missingGroups {
            var policy = FanPolicy()
            let decision = policy.evaluate(snapshot: snapshot(readings: readings), mode: .cool, now: 0, sampleAge: 0)
            #expect(decision.action == .fault)
            #expect(decision.targets.isEmpty)
        }
    }

    @Test(arguments: [-0.001, 120.001, Double.nan, .infinity, -.infinity])
    func everyRequiredTemperatureMustBeValid(invalid: Double) {
        for group in ["cpu", "gpu"] {
            var readings = temperatures()
            readings.append(TemperatureReading(key: "extra-\(group)", name: "Extra", celsius: invalid, group: group))
            var policy = FanPolicy()
            #expect(policy.evaluate(snapshot: snapshot(readings: readings), mode: .cool, now: 0, sampleAge: 0).action == .fault)
        }
    }

    @Test func invalidAncillaryReadingsAreNotSilentlyDropped() {
        var policy = FanPolicy()
        let readings = temperatures() + [TemperatureReading(key: "other", name: "Other", celsius: .nan, group: "other")]
        #expect(policy.evaluate(snapshot: snapshot(readings: readings), mode: .cool, now: 0, sampleAge: 0).action == .fault)
    }

    @Test func validZeroTemperatureRemainsSystemAnd120TriggersSafety() {
        var policy = FanPolicy()
        #expect(policy.evaluate(snapshot: snapshot(cpu: 0, gpu: 0), mode: .cool, now: 0, sampleAge: 0).action == .system)
        let decision = policy.evaluate(snapshot: snapshot(cpu: 120), mode: .cool, now: 1, sampleAge: 0)
        #expect(decision.action == .system)
        #expect(decision.reason.hasPrefix("安全暂停"))
    }

    @Test(arguments: invalidFans)
    func invalidFanFieldsFault(fan: FanReading) {
        var policy = FanPolicy()
        let decision = policy.evaluate(snapshot: snapshot(fans: [fan]), mode: .cool, now: 0, sampleAge: 0)
        #expect(decision.action == .fault)
        #expect(decision.targets.isEmpty)
    }

    @Test func emptyFansAndDuplicateIdentifiersFault() {
        for fans in [[], [fan(), fan()]] {
            var policy = FanPolicy()
            #expect(policy.evaluate(snapshot: snapshot(fans: fans), mode: .cool, now: 0, sampleAge: 0).action == .fault)
        }
    }

    @Test func zeroFeedbackInAutomaticModeIsValidAndTargetIsBounded() {
        var policy = FanPolicy()
        let decision = policy.evaluate(snapshot: snapshot(fans: [fan(actual: 0, target: 0)]), mode: .cool, now: 0, sampleAge: 0)
        #expect(decision.action == .targets)
        #expect(decision.targets[0] == 3_600)
    }

    @Test(arguments: [CoolingMode.cool, .boost])
    func highTemperatureOrPressureRequiresLatchedWorkerPause(mode: CoolingMode) {
        for sample in [snapshot(cpu: 90), snapshot(cpu: 49, gpu: 90), snapshot(cpu: 45, gpu: 45, pressure: 2), snapshot(pressure: 3)] {
            var policy = FanPolicy()
            let decision = policy.evaluate(snapshot: sample, mode: mode, now: 0, sampleAge: 0)
            #expect(decision.action == .system)
            #expect(decision.targets.isEmpty)
            #expect(decision.reason.hasPrefix("安全暂停"))
            #expect(decision.reason.contains("锁定/暂停"))
            #expect(decision.reason.contains("显式恢复"))
        }
    }

    @Test(arguments: [CoolingMode.cool, .boost])
    func fairThermalPressureDoesNotSuppressValidCooling(mode: CoolingMode) {
        var policy = FanPolicy()
        #expect(policy.evaluate(snapshot: snapshot(pressure: 1), mode: mode, now: 0, sampleAge: 0).action == .targets)
    }

    @Test func safetyHasPriorityOverLeaseExpirationAndObservation() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 0, sampleAge: 0)
        let expiration = policy.evaluate(snapshot: snapshot(cpu: 90), mode: .cool, now: 45, sampleAge: 0)
        #expect(expiration.reason.hasPrefix("安全暂停"))
        _ = policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 46, sampleAge: 0)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 58), mode: .cool, now: 54, sampleAge: 0).action == .hold)
        let observing = policy.evaluate(snapshot: snapshot(pressure: 2), mode: .cool, now: 55, sampleAge: 0)
        #expect(observing.reason.hasPrefix("安全暂停"))
    }

    @Test func validSafetyAlarmCannotBeHiddenByAnotherInvalidField() {
        for sample in [
            snapshot(cpu: 90, gpu: .nan, fans: []),
            snapshot(readings: [], fans: [], pressure: 2, supported: false, issues: ["read failed"]),
        ] {
            var policy = FanPolicy()
            let decision = policy.evaluate(snapshot: sample, mode: .cool, now: .nan, sampleAge: 99)
            #expect(decision.action == .system)
            #expect(decision.targets.isEmpty)
            #expect(decision.reason.hasPrefix("安全暂停"))
        }
        // An out-of-domain temperature or pressure is not a trusted alarm.
        for sample in [snapshot(cpu: 121), snapshot(pressure: 4)] {
            var policy = FanPolicy()
            #expect(policy.evaluate(snapshot: sample, mode: .cool, now: 0, sampleAge: 0).action == .fault)
        }
    }

    @Test func comfortCurveStartsAtFortyPercentAndStopsAtTheEightyPercentCeiling() throws {
        // 曲线本身在 75°C 会算到 6000，但每个下发目标都夹在 max(minimum, maximum × 0.8) 内，
        // 默认风扇因此封顶 4800；62.5°C 及以下仍是曲线原值。
        for (temperature, expected) in [(50.0, 3_600.0), (55.0, 4_080.0), (62.5, 4_800.0), (75.0, 4_800.0), (89.999, 4_800.0)] {
            var policy = FanPolicy()
            let decision = policy.evaluate(snapshot: snapshot(cpu: temperature), mode: .cool, now: 0, sampleAge: 0)
            #expect(decision.action == .targets)
            let target = try #require(decision.targets[0])
            #expect(abs(target - expected) < 0.000_001)
            #expect(target <= 4_800)
            #expect(decision.reason.contains("舒适偏好"))
        }
    }

    @Test func maximumOfAllRequiredReadingsDrivesCurve() {
        var policy = FanPolicy()
        let readings = temperatures(cpu: 50, gpu: 60) + [
            TemperatureReading(key: "extra-cpu", name: "Extra CPU", celsius: 75, group: "cpu"),
            TemperatureReading(key: "extra-gpu", name: "Extra GPU", celsius: 70, group: "gpu"),
        ]
        #expect(policy.evaluate(snapshot: snapshot(readings: readings), mode: .cool, now: 0, sampleAge: 0).targets[0] == 4_800)
    }

    @Test func ancillaryTemperatureDoesNotSubstituteForRequiredGroupsOrDriveCurve() {
        var policy = FanPolicy()
        let readings = temperatures(cpu: 40, gpu: 40) + [
            TemperatureReading(key: "other", name: "Other", celsius: 80, group: "other"),
        ]
        #expect(policy.evaluate(snapshot: snapshot(readings: readings), mode: .cool, now: 0, sampleAge: 0).action == .system)
    }

    @Test func firstTargetNeverDecreasesActualOrExistingTargetAndRespectsFanBounds() {
        // 实测或既有目标更高时只取更高的值，但所有目标仍夹在 80% 上限内：6000 × 0.8 = 4800。
        for (actual, target, expected) in [(4_500.0, 4_000.0, 4_500.0), (3_000.0, 5_000.0, 4_800.0), (6_000.0, 6_000.0, 4_800.0)] {
            var policy = FanPolicy()
            let decision = policy.evaluate(snapshot: snapshot(fans: [fan(actual: actual, target: target)]), mode: .cool, now: 0, sampleAge: 0)
            #expect(decision.action == .targets)
            #expect(decision.targets[0] == expected)
            #expect((decision.targets[0] ?? 0) <= 4_800)
        }
    }

    @Test func allFansReceiveTheirOwnBoundedTargetWithoutAssumingContiguousIDs() {
        var policy = FanPolicy()
        let fans = [fan(id: 7, minimum: 2_000, maximum: 7_000), fan(id: 0, minimum: 1_000, maximum: 5_000)]
        let decision = policy.evaluate(snapshot: snapshot(cpu: 62.5, fans: fans), mode: .cool, now: 0, sampleAge: 0)
        #expect(decision.targets == [0: 3_800, 7: 5_500])
        #expect(policy.evaluate(snapshot: snapshot(cpu: 62.5, fans: Array(fans.reversed())), mode: .cool, now: 1, sampleAge: 0).action == .hold)
    }

    @Test func activeTargetsCanOnlyIncreaseAndHoldDoesNotWriteRPMs() {
        var policy = FanPolicy()
        let first = policy.evaluate(snapshot: snapshot(), mode: .cool, now: 0, sampleAge: 0)
        let second = policy.evaluate(snapshot: snapshot(cpu: 55), mode: .cool, now: 1, sampleAge: 0)
        let hold = policy.evaluate(snapshot: snapshot(cpu: 55), mode: .cool, now: 2, sampleAge: 0)
        let third = policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 3, sampleAge: 0)
        #expect(first.targets[0] == 3_600)
        #expect(second.targets[0] == 4_080)
        #expect(hold.action == .hold)
        #expect(hold.targets.isEmpty)
        #expect(third.targets[0] == 4_560)
    }

    @Test func updatedFeedbackCanRaiseButNeverLowerActiveTargets() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 0, sampleAge: 0)
        let raised = policy.evaluate(snapshot: snapshot(cpu: 60, fans: [fan(actual: 4_800, target: 4_700)]), mode: .cool, now: 1, sampleAge: 0)
        #expect(raised.targets[0] == 4_800)
        let held = policy.evaluate(snapshot: snapshot(cpu: 60, fans: [fan(actual: 4_000, target: 4_800)]), mode: .cool, now: 2, sampleAge: 0)
        // 偏好目标（4560）低于已下发的 4800：只保持，不写更低值，也不提前交还。
        #expect(held.action == .hold)
        #expect(held.targets.isEmpty)
        #expect(held.commandedRPM == 4_800)
        // 交还只由温度决定：降到退出阈值才交还，回落 2°C 不再触发。
        let stillWarm = policy.evaluate(snapshot: snapshot(cpu: 58, fans: [fan(actual: 4_000, target: 4_800)]), mode: .cool, now: 8, sampleAge: 0)
        #expect(stillWarm.action == .hold)
        let release = policy.evaluate(snapshot: snapshot(cpu: 41, gpu: 41, fans: [fan(actual: 4_000, target: 4_800)]), mode: .cool, now: 9, sampleAge: 0)
        #expect(release.action == .system)
        #expect(release.targets.isEmpty)
        #expect(release.reason.contains("退出阈值"))
    }

    @Test func stableTemperatureWithLowerPreferenceThanInitialFloorHoldsWithoutReducing() {
        var policy = FanPolicy()
        // 实测 5000 高于曲线在 50°C 的 3600，但下发目标仍夹在 80% 上限 4800。
        let initial = policy.evaluate(snapshot: snapshot(fans: [fan(actual: 5_000, target: 4_000)]), mode: .cool, now: 0, sampleAge: 0)
        #expect(initial.targets[0] == 4_800)
        for now in [1.0, 8, 44.999] {
            let held = policy.evaluate(snapshot: snapshot(fans: [fan(actual: 5_000, target: 5_000, manual: true)]), mode: .cool, now: now, sampleAge: 0)
            #expect(held.action == .hold)
            #expect(held.targets.isEmpty)
            #expect(held.reason.contains("保持原目标"))
            #expect(held.reason.contains("不写更低转速"))
            #expect(held.commandedRPM == 4_800)
        }
        // 温度没降下来就一直吹：很久之后仍在接管，直到降到退出阈值。
        for now in [45.0, 600, 1799.999] {
            let held = policy.evaluate(snapshot: snapshot(fans: [fan(actual: 5_000, target: 5_000, manual: true)]), mode: .cool, now: now, sampleAge: 0)
            #expect(held.action == .hold)
            #expect(held.commandedRPM == 4_800)
        }
        let release = policy.evaluate(snapshot: snapshot(cpu: 41, gpu: 41), mode: .cool, now: 1800, sampleAge: 0)
        #expect(release.action == .system)
        #expect(release.reason.contains("退出阈值"))
        // 30 分钟硬上限只作为传感器卡死的兜底，不是常规路径。
        #expect(policy.evaluate(snapshot: snapshot(cpu: 75), mode: .cool, now: 1800.001, sampleAge: 0).action == .system)
    }

    @Test func temperatureJitterHoldsEvenOnMaximumRPMPlateauUntilStableDrop() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 80), mode: .cool, now: 0, sampleAge: 0)
        for (temperature, now) in [(79.999, 1.0), (79, 2), (78, 7.999)] {
            let held = policy.evaluate(snapshot: snapshot(cpu: temperature), mode: .cool, now: now, sampleAge: 0)
            #expect(held.action == .hold)
            #expect(held.targets.isEmpty)
        }
        // 抖动和峰值回落都不再交还；只有降到退出阈值才交还。
        let stillWarm = policy.evaluate(snapshot: snapshot(cpu: 78), mode: .cool, now: 8, sampleAge: 0)
        #expect(stillWarm.action == .hold)
        #expect(stillWarm.targets.isEmpty)
        let decision = policy.evaluate(snapshot: snapshot(cpu: 41, gpu: 41), mode: .cool, now: 9, sampleAge: 0)
        #expect(decision.action == .system)
        #expect(decision.targets.isEmpty)
        #expect(decision.reason.contains("退出阈值"))
    }

    @Test func coolingHoldsThroughAnyTemperatureAboveExitAndReleasesAtThreshold() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 0, sampleAge: 0)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 61), mode: .cool, now: 1, sampleAge: 0).action == .targets)
        // 缓慢降温一路保持接管，不因回落幅度或时间而提前交还。
        for (temperature, now) in [(60.0, 2.0), (59.5, 3), (59, 7.999), (59.001, 8), (50, 60), (46, 120)] {
            let held = policy.evaluate(snapshot: snapshot(cpu: temperature), mode: .cool, now: now, sampleAge: 0)
            #expect(held.action == .hold)
            #expect(held.targets.isEmpty)
        }
        let released = policy.evaluate(snapshot: snapshot(cpu: 41, gpu: 41), mode: .cool, now: 121, sampleAge: 0)
        #expect(released.action == .system)
        #expect(released.targets.isEmpty)
        #expect(released.reason.contains("退出阈值"))
        // 交还后仍需满 5 秒观察才能重新接管。
        #expect(policy.evaluate(snapshot: snapshot(cpu: 61), mode: .cool, now: 125.999, sampleAge: 0).action == .system)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 61), mode: .cool, now: 126, sampleAge: 0).action == .targets)
    }

    @Test func oneDegreeJitterAfterMinimumDurationHoldsThenHeatingCanRaiseTarget() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 50), mode: .cool, now: 0, sampleAge: 0)
        let raised = policy.evaluate(snapshot: snapshot(cpu: 51), mode: .cool, now: 1, sampleAge: 0)
        #expect(raised.targets[0] == 3_696)
        for (temperature, now) in [(50.0, 8.0), (50.5, 9), (51, 10)] {
            let held = policy.evaluate(snapshot: snapshot(cpu: temperature), mode: .cool, now: now, sampleAge: 0)
            #expect(held.action == .hold)
            #expect(held.targets.isEmpty)
        }
        let increased = policy.evaluate(snapshot: snapshot(cpu: 52), mode: .cool, now: 11, sampleAge: 0)
        #expect(increased.action == .targets)
        #expect(increased.targets[0] == 3_792)
    }

    @Test func lowTemperatureExitAndSafetyBypassMinimumControlDuration() {
        for sample in [snapshot(cpu: 41, gpu: 40), snapshot(cpu: 90), snapshot(pressure: 2), snapshot(pressure: 3)] {
            var policy = FanPolicy()
            _ = policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 0, sampleAge: 0)
            let released = policy.evaluate(snapshot: sample, mode: .cool, now: 1, sampleAge: 0)
            #expect(released.action == .system)
            #expect(released.targets.isEmpty)
            #expect(released.reason.contains("退出阈值") || released.reason.hasPrefix("安全暂停"))
        }
    }

    @Test func entryAndExitHysteresisPersistsAcrossSystemObservation() {
        var policy = FanPolicy()
        #expect(policy.evaluate(snapshot: snapshot(cpu: 49.999, gpu: 49), mode: .cool, now: 0, sampleAge: 0).action == .system)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 1, sampleAge: 0).action == .targets)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 48, gpu: 47), mode: .cool, now: 2, sampleAge: 0).action == .hold)
        // 48°C 仍高于退出阈值：继续保持接管，不再按 2°C 回落交还。
        #expect(policy.evaluate(snapshot: snapshot(cpu: 48, gpu: 47), mode: .cool, now: 9, sampleAge: 0).action == .hold)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 47, gpu: 46), mode: .cool, now: 13.999, sampleAge: 0).action == .hold)
        // 45°C 仍在滞回带内，继续吹；真正降到 42°C 才交还。
        #expect(policy.evaluate(snapshot: snapshot(cpu: 45, gpu: 44), mode: .cool, now: 14, sampleAge: 0).action == .hold)
        let exit = policy.evaluate(snapshot: snapshot(cpu: 41, gpu: 40), mode: .cool, now: 15, sampleAge: 0)
        #expect(exit.action == .system)
        #expect(exit.reason.contains("退出阈值"))
        #expect(policy.evaluate(snapshot: snapshot(cpu: 49, gpu: 48), mode: .cool, now: 19.999, sampleAge: 0).action == .system)
        let reentry = policy.evaluate(snapshot: snapshot(), mode: .cool, now: 20, sampleAge: 0)
        #expect(reentry.action == .targets)
        #expect(reentry.targets[0] == 3_600)
    }

    @Test func coolingRunsUntilTheExitThresholdAndThenObservesFiveSeconds() {
        var policy = FanPolicy()
        #expect(policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 100, sampleAge: 0).targets[0] == 4_560)
        // 只要还在 45°C 以上，就一直保持接管，没有短周期上限。
        for now in [110.0, 130, 600, 1_000, 1_899] {
            #expect(policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: now, sampleAge: 0).action == .hold)
        }
        let release = policy.evaluate(snapshot: snapshot(cpu: 41, gpu: 41), mode: .cool, now: 1_900, sampleAge: 0)
        #expect(release.action == .system)
        #expect(release.targets.isEmpty)
        #expect(release.reason.contains("退出阈值"))
        // 交还后是精确的 5 秒观察边界。
        #expect(policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 1_904.999, sampleAge: 0).action == .system)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 1_905, sampleAge: 0).action == .targets)
    }

    @Test func demandExitingDuringObservationRequiresAFreshEntryThreshold() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 0, sampleAge: 0)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 58), mode: .cool, now: 8, sampleAge: 0).action == .hold)
        _ = policy.evaluate(snapshot: snapshot(cpu: 41, gpu: 40), mode: .cool, now: 9, sampleAge: 0)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 49, gpu: 48), mode: .cool, now: 13.999, sampleAge: 0).action == .system)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 14, sampleAge: 0).action == .targets)
    }

    @Test func fanTopologyChangeDuringControlFaultsWithoutPartialTargets() {
        for fans in [[fan(id: 1)], [fan(), fan(id: 1)], [fan(maximum: 3_500)], [fan(minimum: 4_000)]] {
            var policy = FanPolicy()
            _ = policy.evaluate(snapshot: snapshot(), mode: .cool, now: 0, sampleAge: 0)
            let decision = policy.evaluate(snapshot: snapshot(fans: fans), mode: .cool, now: 1, sampleAge: 0)
            #expect(decision.action == .fault)
            #expect(decision.targets.isEmpty)
        }
    }

    @Test func modeSwitchesResetStateButRepeatedEvaluationsDoNot() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 75), mode: .cool, now: 0, sampleAge: 0)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .boost, now: 1, sampleAge: 0).targets[0] == 4_800)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 2, sampleAge: 0).targets[0] == 3_600)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 46.999, sampleAge: 0).action == .hold)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 47, sampleAge: 0).action == .hold)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 41, gpu: 41), mode: .cool, now: 48, sampleAge: 0).action == .system)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .system, now: 49, sampleAge: 0).action == .system)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 49, gpu: 48), mode: .cool, now: 50, sampleAge: 0).action == .system)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 51, sampleAge: 0).action == .targets)
    }

    @Test func switchingThroughBoostClearsCoolObservationState() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 60), mode: .cool, now: 0, sampleAge: 0)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 58), mode: .cool, now: 8, sampleAge: 0).action == .hold)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .boost, now: 9, sampleAge: 0).action == .targets)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 10, sampleAge: 0).action == .targets)
    }

    @Test func explicitResetClearsDemandTargetsAndTimeHistory() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 75), mode: .cool, now: 100, sampleAge: 0)
        policy.reset()
        #expect(policy.evaluate(snapshot: snapshot(cpu: 49, gpu: 48), mode: .cool, now: 0, sampleAge: 0).action == .system)
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 1, sampleAge: 0).targets[0] == 3_600)
    }

    @Test func boostAlwaysRequestsEachBoundedMaximumAndLeavesTotalDeadlineToWorker() {
        var policy = FanPolicy()
        let fans = [fan(), fan(id: 7, maximum: 7_000)]
        // 每个风扇取自己的 80% 上限：6000 × 0.8 = 4800，7000 × 0.8 = 5600。
        // No renew-specific policy reset, nor a rolling 120-second policy timer.
        // The real worker must stop the mode at its original total deadline.
        for now in [0.0, 30, 119.999, 120, 1_000] {
            let decision = policy.evaluate(snapshot: snapshot(fans: fans), mode: .boost, now: now, sampleAge: 0)
            #expect(decision.action == .targets)
            #expect(decision.targets == [0: 4_800, 7: 5_600])
            #expect(decision.commandedRPM == 5_600)
            #expect(decision.reason.contains("80% 上限"))
            #expect(decision.reason.contains("120 秒总期限"))
        }
    }

    @Test func faultDropsPreviouslyCommandedTargetsAndNeverReturnsStaleCommands() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 75), mode: .cool, now: 0, sampleAge: 0)
        let failed = policy.evaluate(snapshot: snapshot(), mode: .cool, now: 1, sampleAge: 3.001)
        #expect(failed.action == .fault)
        #expect(failed.targets.isEmpty)
        // Only the worker may decide whether to resume after exposing a fault.
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, now: 2, sampleAge: 0).targets[0] == 3_600)
    }

    // MARK: - 增强档位（enhancement）

    /// 同一个档位 0 的显式调用必须与不带 enhancement 的入口逐步完全一致。
    @Test func zeroEnhancementMatchesTheOriginalEntryPointStepForStep() {
        let samples: [(cpu: Double, now: Double, mode: CoolingMode)] = [
            (50, 0, .cool), (51, 1, .cool), (50, 8, .cool), (51, 14, .cool),
            (90, 15, .cool), (51, 16, .cool), (45, 17, .cool), (50, 23, .cool),
            (50, 68, .cool), (50, 73, .cool), (50, 73, .boost), (50, 74, .system), (50, 75, .cool),
        ]
        var plain = FanPolicy()
        var explicitZero = FanPolicy()
        for sample in samples {
            let reading = snapshot(cpu: sample.cpu)
            let original = plain.evaluate(snapshot: reading, mode: sample.mode, now: sample.now, sampleAge: 0)
            let zero = explicitZero.evaluate(snapshot: reading, mode: sample.mode, enhancement: 0, now: sample.now, sampleAge: 0)
            #expect(original == zero)
        }
        // 逐步相等还要求这条序列本身覆盖到接管、保持与交还，否则断言会退化成空跑。
        #expect(plain.evaluate(snapshot: snapshot(cpu: 51), mode: .cool, now: 76, sampleAge: 0).action == .targets)
        #expect(plain.evaluate(snapshot: snapshot(cpu: 51), mode: .cool, now: 77, sampleAge: 0).action == .hold)
    }

    @Test(arguments: [1, 5, -10, 85, 90, 100, Int.max, Int.min])
    func enhancementStepsOffTheTenPercentGridFault(enhancement: Int) {
        var policy = FanPolicy()
        let decision = policy.evaluate(snapshot: snapshot(), mode: .cool, enhancement: enhancement, now: 0, sampleAge: 0)
        #expect(decision.action == .fault)
        #expect(decision.targets.isEmpty)
        #expect(decision.reason.contains("增强档位"))
        #expect(decision.baselineRPM == nil)
        #expect(decision.commandedRPM == nil)
        // 故障后状态被清空，恢复受支持的档位即可重新接管。
        let recovered = policy.evaluate(snapshot: snapshot(), mode: .cool, enhancement: 40, now: 1, sampleAge: 0)
        #expect(recovered.action == .targets)
        #expect(recovered.targets[0] == 3_600)
    }

    @Test(arguments: Enhancement.steps)
    func everySupportedEnhancementStepIsAcceptedAndBounded(enhancement: Int) {
        var policy = FanPolicy()
        let decision = policy.evaluate(snapshot: snapshot(), mode: .cool, enhancement: enhancement, now: 0, sampleAge: 0)
        #expect(decision.action == .targets)
        #expect(decision.targets[0] == 3_600)
        #expect((decision.targets[0] ?? 0) <= 4_800)
    }

    @Test func enhancementBaselineIsTheHighestOfSystemTargetActualAndMinimum() {
        var policy = FanPolicy()
        let decision = policy.evaluate(snapshot: snapshot(fans: [fan(actual: 2_400, target: 2_600)]), mode: .cool, enhancement: 40, now: 0, sampleAge: 0)
        #expect(decision.action == .targets)
        // 系统目标 2600 高于实测 2400 与最小转速 2000。
        #expect(decision.baselineRPM == 2_600)
        // 2600 × 1.4 = 3640 高于 50°C 的曲线值 3600，所以目标是基准的加成值。
        #expect(abs((decision.targets[0] ?? 0) - 3_640) < 0.000_001)
        #expect(decision.commandedRPM == decision.targets[0])
    }

    @Test func stoppedSystemFanUsesTheMinimumAsBaselineInsteadOfZero() {
        var policy = FanPolicy()
        let decision = policy.evaluate(snapshot: snapshot(fans: [fan(actual: 0, target: 0)]), mode: .cool, enhancement: 40, now: 0, sampleAge: 0)
        #expect(decision.action == .targets)
        // 系统停转时基准是最小转速，而不是 0；否则按百分比提速将毫无意义。
        #expect(decision.baselineRPM == 2_000)
        // 2000 × 1.4 = 2800 低于 50°C 的曲线值，取曲线值 3600。
        #expect(decision.targets[0] == 3_600)
    }

    @Test func enhancementNeverCommandsBelowTheSystemRequirementOrTheCurve() {
        // 30°C 低于 50°C 舒适偏好进入阈值，增强档位仍会接管。
        var policy = FanPolicy()
        let raised = policy.evaluate(snapshot: snapshot(cpu: 30, gpu: 30, fans: [fan(actual: 4_000, target: 4_000)]), mode: .cool, enhancement: 20, now: 0, sampleAge: 0)
        #expect(raised.action == .targets)
        #expect(raised.baselineRPM == 4_000)
        #expect(raised.targets[0] == 4_800)
        #expect(raised.commandedRPM == 4_800)
        // 档位更低时加成更小，但仍不得低于系统自己的目标。
        var lower = FanPolicy()
        let bounded = lower.evaluate(snapshot: snapshot(cpu: 30, gpu: 30, fans: [fan(actual: 4_000, target: 4_000)]), mode: .cool, enhancement: 10, now: 0, sampleAge: 0)
        #expect(bounded.targets[0] == 4_400)
        #expect((bounded.targets[0] ?? 0) >= 4_000)
    }

    @Test func enhancementHoldNeverWritesALowerTargetWhileTakenOver() {
        var policy = FanPolicy()
        // Take over from a real automatic sample at 60°C, where the comfort curve
        // sets a higher target than the step alone would.
        let automatic = policy.evaluate(snapshot: snapshot(cpu: 60, gpu: 60, fans: [fan(actual: 4_000, target: 4_000)]), mode: .cool, enhancement: 10, now: 0, sampleAge: 0)
        #expect(automatic.action == .targets)
        #expect(automatic.baselineRPM == 4_000)
        #expect(automatic.targets[0] == 4_560)
        // The machine cools below the curve threshold while the fan is ours, so the
        // recomputed target would be lower. That must hold, never write a decrease.
        let held = policy.evaluate(snapshot: snapshot(cpu: 40, gpu: 40, fans: [fan(actual: 4_560, target: 4_560, manual: true)]), mode: .cool, enhancement: 10, now: 1, sampleAge: 0)
        #expect(held.action == .hold)
        #expect(held.targets.isEmpty)
        #expect(held.reason.contains("不写更低转速"))
        #expect(held.baselineRPM == 4_000)
        #expect(held.commandedRPM == 4_560)
        #expect((held.commandedRPM ?? 0) <= 4_800)
        // 目标没有变低之前一直保持，不会回落到基准加成值。
        let stillHeld = policy.evaluate(snapshot: snapshot(cpu: 40, gpu: 40, fans: [fan(actual: 4_560, target: 4_560, manual: true)]), mode: .cool, enhancement: 10, now: 2, sampleAge: 0)
        #expect(stillHeld.action == .hold)
        #expect(stillHeld.targets.isEmpty)
        #expect(stillHeld.commandedRPM == 4_560)
    }

    @Test func enhancementDecisionsExposeTheBaselineAndTheBoundedCommand() {
        var policy = FanPolicy()
        let entry = policy.evaluate(snapshot: snapshot(fans: [fan(actual: 2_000, target: 3_000)]), mode: .cool, enhancement: 40, now: 0, sampleAge: 0)
        #expect(entry.action == .targets)
        #expect(entry.baselineRPM == 3_000)
        #expect(entry.commandedRPM == 4_200)
        #expect((entry.commandedRPM ?? 0) <= 4_800)
        // 接管后系统目标字段变成我们自己的命令，基准仍取接管前读到的系统目标。
        let held = policy.evaluate(snapshot: snapshot(fans: [fan(actual: 2_000, target: 2_000, manual: true)]), mode: .cool, enhancement: 40, now: 1, sampleAge: 0)
        #expect(held.action == .hold)
        #expect(held.targets.isEmpty)
        #expect(held.baselineRPM == 3_000)
        #expect(held.commandedRPM == 4_200)
        // 交还系统时不携带任何基准或命令。
        let restored = policy.evaluate(snapshot: snapshot(), mode: .system, enhancement: 40, now: 2, sampleAge: 0)
        #expect(restored.action == .system)
        #expect(restored.targets.isEmpty)
        #expect(restored.baselineRPM == nil)
        #expect(restored.commandedRPM == nil)
    }

    @Test func enhancementKeepsEachFanInsideItsOwnEightyPercentCeiling() {
        var policy = FanPolicy()
        let fans = [fan(id: 7, minimum: 2_000, maximum: 7_000), fan(id: 0, minimum: 1_000, maximum: 5_000)]
        let decision = policy.evaluate(snapshot: snapshot(fans: fans), mode: .cool, enhancement: 40, now: 0, sampleAge: 0)
        #expect(decision.action == .targets)
        // 上限分别是 5600 与 4000，基准加成不得越过各自的上限。
        #expect(decision.targets == [0: 2_800, 7: 4_000])
        #expect(decision.commandedRPM == 4_000)
    }

    @Test func enhancementCycleUsesTheSameThirtyMinuteSensorGuard() {
        var policy = FanPolicy()
        let entry = policy.evaluate(snapshot: snapshot(), mode: .cool, enhancement: 40, now: 0, sampleAge: 0)
        #expect(entry.action == .targets)
        #expect(entry.baselineRPM == 2_000)
        #expect(entry.targets[0] == 3_600)
        for now in [45.0, 179.999, 1_000, 1_799.999] {
            #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, enhancement: 40, now: now, sampleAge: 0).action == .hold)
        }
        let expiry = policy.evaluate(snapshot: snapshot(), mode: .cool, enhancement: 40, now: 1_800, sampleAge: 0)
        #expect(expiry.action == .system)
        #expect(expiry.targets.isEmpty)
        #expect(expiry.reason.contains("30 分钟"))
        // 交还后同样是精确的 5 秒观察边界。
        #expect(policy.evaluate(snapshot: snapshot(), mode: .cool, enhancement: 40, now: 1_804.999, sampleAge: 0).action == .system)
        let reentry = policy.evaluate(snapshot: snapshot(), mode: .cool, enhancement: 40, now: 1_805, sampleAge: 0)
        #expect(reentry.action == .targets)
        #expect(reentry.targets[0] == 3_600)
    }

    @Test(arguments: [CoolingMode.cool, .boost])
    func enhancementStillHandsBackOnSafetyAlarms(mode: CoolingMode) {
        for sample in [snapshot(cpu: 90), snapshot(cpu: 49, gpu: 90), snapshot(cpu: 45, gpu: 45, pressure: 2), snapshot(pressure: 3)] {
            var policy = FanPolicy()
            let decision = policy.evaluate(snapshot: sample, mode: mode, enhancement: 40, now: 0, sampleAge: 0)
            #expect(decision.action == .system)
            #expect(decision.targets.isEmpty)
            #expect(decision.reason.hasPrefix("安全暂停"))
            #expect(decision.reason.contains("锁定/暂停"))
            #expect(decision.reason.contains("显式恢复"))
        }
    }

    @Test func boostIsAlreadyTheBoundedMaximumSoTheEnhancementStepAddsNothing() {
        for enhancement in [0, 40, 80] {
            var policy = FanPolicy()
            let decision = policy.evaluate(snapshot: snapshot(), mode: .boost, enhancement: enhancement, now: 0, sampleAge: 0)
            #expect(decision.action == .targets)
            #expect(decision.targets == [0: 4_800])
            #expect(decision.reason.contains("80% 上限"))
        }
    }

    @Test func enhancementIsAppliedOnceToTheSystemSpeedAndNeverCompounds() {
        var policy = FanPolicy()
        // The system is asking for 2000 RPM on a cool machine: the comfort curve
        // is out of the picture, so only the step decides.
        let automatic = snapshot(cpu: 30, gpu: 29, fans: [fan(actual: 2_000, target: 2_000)])
        let first = policy.evaluate(snapshot: automatic, mode: .cool, enhancement: 30, now: 0, sampleAge: 0)
        #expect(first.action == .targets)
        #expect(abs(first.targets[0]! - 2_600) < 0.001)
        #expect(first.baselineRPM == 2_000)

        // Now the fan is ours: the reported target and actual RPM are our own
        // command. Re-evaluating must hold 2600 instead of multiplying again.
        var held = first.targets[0]!
        for step in 1...6 {
            let owned = snapshot(cpu: 30, gpu: 29,
                                 fans: [fan(actual: held, target: held, manual: true)])
            let decision = policy.evaluate(snapshot: owned, mode: .cool, enhancement: 30,
                                           now: Double(step), sampleAge: 0)
            if decision.action == .targets {
                held = decision.targets[0]!
            }
            #expect(abs(held - 2_600) < 0.001)
            #expect(decision.baselineRPM == 2_000)
        }
    }

    /// Chip sensors jitter by a degree or more. A single release threshold made
    /// the fan stop and restart every few seconds; the hysteresis band must keep
    /// one continuous cooling run through that jitter.
    @Test func sensorJitterAroundTheOldThresholdCannotStopAndRestartCooling() {
        var policy = FanPolicy()
        #expect(policy.evaluate(snapshot: snapshot(cpu: 52), mode: .cool, now: 0, sampleAge: 0).action == .targets)
        // 45–47°C 来回抖动：全程保持接管，一次都不交还。
        for (index, temperature) in [45.2, 46.8, 44.9, 47.1, 45.0, 46.2, 44.5, 45.9].enumerated() {
            let decision = policy.evaluate(snapshot: snapshot(cpu: temperature, gpu: temperature - 1),
                                           mode: .cool, now: Double(index + 1), sampleAge: 0)
            #expect(decision.action != .system, "在 \(temperature)°C 时不应交还")
        }
        // 真正凉下来才交还，并且之后需要满 5 秒观察。
        let released = policy.evaluate(snapshot: snapshot(cpu: 41, gpu: 40), mode: .cool, now: 20, sampleAge: 0)
        #expect(released.action == .system)
        #expect(released.reason.contains("退出阈值"))
        #expect(policy.evaluate(snapshot: snapshot(cpu: 52), mode: .cool, now: 24.999, sampleAge: 0).action == .system)
        #expect(policy.evaluate(snapshot: snapshot(cpu: 52), mode: .cool, now: 25, sampleAge: 0).action == .targets)
    }

    /// A machine that only drifts to 46°C must never enter manual control at all.
    @Test func idleMachineBelowTheEntryThresholdNeverTakesOver() {
        var policy = FanPolicy()
        for (index, temperature) in [46.0, 47.5, 45.5, 48.0, 44.0].enumerated() {
            let decision = policy.evaluate(snapshot: snapshot(cpu: temperature, gpu: temperature - 1),
                                           mode: .cool, now: Double(index), sampleAge: 0)
            #expect(decision.action == .system)
        }
    }

    @Test func enhancementBaselineIsRefreshedOnlyFromAnAutomaticSample() {
        var policy = FanPolicy()
        _ = policy.evaluate(snapshot: snapshot(cpu: 30, gpu: 29, fans: [fan(actual: 2_000, target: 2_000)]),
                            mode: .cool, enhancement: 50, now: 0, sampleAge: 0)
        // The system later wants much more while we are not holding the fan.
        let hotter = policy.evaluate(snapshot: snapshot(cpu: 30, gpu: 29, fans: [fan(actual: 4_000, target: 4_000)]),
                                     mode: .cool, enhancement: 50, now: 1, sampleAge: 0)
        #expect(hotter.baselineRPM == 4_000)
    }

    /// The user's chosen behaviour: once cooling starts it keeps running for as
    /// long as the chip stays warm, and only the exit threshold hands it back.
    /// A long, steady warm load must never be interrupted by a timer.
    @Test func warmLoadKeepsCoolingForHoursWithoutHandingBack() {
        var policy = FanPolicy()
        let first = policy.evaluate(snapshot: snapshot(cpu: 62), mode: .cool, now: 0, sampleAge: 0)
        #expect(first.action == .targets)
        var now = 1.0
        while now < 1_700 {
            let decision = policy.evaluate(snapshot: snapshot(cpu: 62, gpu: 60), mode: .cool, now: now, sampleAge: 0)
            #expect(decision.action == .hold)
            now += 60
        }
        // Cooling the chip down is the only thing that ends the cycle.
        let released = policy.evaluate(snapshot: snapshot(cpu: 41, gpu: 40), mode: .cool, now: now, sampleAge: 0)
        #expect(released.action == .system)
        #expect(released.reason.contains("退出阈值"))
    }
}
