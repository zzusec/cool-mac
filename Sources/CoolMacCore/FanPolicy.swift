/// The worker must restore automatic control for both `system` and `fault`.
/// `hold` means no new RPM write; only `targets` carries RPM commands.
public enum PolicyAction: Equatable, Sendable {
    case system, targets, hold, fault
}

public struct PolicyDecision: Equatable, Sendable {
    public let action: PolicyAction
    public let targets: [Int: Double]
    public let reason: String
    /// The observed automatic target this cycle's enhancement was based on.
    public let baselineRPM: Double?
    /// The single commanded target, when all fans share it (Mac14,7 has one fan).
    public let commandedRPM: Double?

    public init(action: PolicyAction, targets: [Int: Double], reason: String, baselineRPM: Double? = nil, commandedRPM: Double? = nil) {
        self.action = action
        self.targets = targets
        self.reason = reason
        self.baselineRPM = baselineRPM
        self.commandedRPM = commandedRPM
    }
}

/// A hardware-free policy driven exclusively by caller-supplied monotonic time.
///
/// CPU and GPU groups must both be present; the hottest reading in those groups
/// drives the preference curve. No missing/invalid temperature is substituted.
/// 50°C entry, 45°C exit and the 40%-to-100% curve are comfort preferences,
/// not Apple's official temperature limits. A cooling cycle holds through
/// small temperature fluctuations; release for cooling requires a drop of at
/// least 2°C from that cycle's peak and at least 8 seconds of control. The
/// 45°C exit, safety alarms and the control-duration cap bypass that stability wait.
///
/// Enhancement is a separate axis: with a non-zero step the policy adds a
/// percentage on top of the speed the system itself was asking for, and holds
/// it for a longer cycle. Apple Silicon has no "system target + offset" mode,
/// so the baseline can only be re-learned during the short observation window
/// after each hand-back. Every commanded target is bounded by
/// `Enhancement.maximumManualFraction` of the rated maximum, including boost.
///
/// Reuse one instance across samples and lease renewals. Mode changes clear
/// mode-specific state automatically. `reset()` is an explicit lifecycle reset,
/// not something to call at every sample or renewal.
///
/// Boost always requests the bounded maximum RPM. Its one-shot, 120-second
/// total deadline belongs to the worker and must not be extended by renewals.
/// A decision whose reason begins with "安全暂停" requires the worker to latch
/// a safety pause, restore automatic control and reject automatic re-entry.
/// A valid critical CPU/GPU reading or pressure alarm takes precedence over
/// other sample faults: even an incomplete/stale snapshot must not hide an alarm.
public struct FanPolicy: Sendable {
    private static let entryTemperature = 50.0
    private static let exitTemperature = 45.0
    private static let maximumPreferenceTemperature = 75.0
    private static let safetyTemperature = 90.0
    private static let maximumSampleAge = 3.0
    private static let minimumControlDuration = 8.0
    private static let releaseTemperatureDrop = 2.0
    private static let maximumControlDuration = 45.0
    private static let enhancedControlDuration = 180.0
    private static let minimumObservationDuration = 5.0

    private var previousMode: CoolingMode?
    private var previousTime: Double?
    private var coolingDemand = false
    private var controlStartedAt: Double?
    private var observationStartedAt: Double?
    private var peakControlTemperature: Double?
    private var commandedTargets: [Int: Double] = [:]
    private var lastSystemTarget: Double?

    public init() {}

    public mutating func reset() {
        previousMode = nil
        previousTime = nil
        coolingDemand = false
        controlStartedAt = nil
        observationStartedAt = nil
        peakControlTemperature = nil
        commandedTargets.removeAll()
        lastSystemTarget = nil
    }

    /// Enhancement-free entry point. Kept so the original temperature-only
    /// behaviour stays exactly reproducible and regression-tested.
    public mutating func evaluate(
        snapshot: HardwareSnapshot,
        mode: CoolingMode,
        now: Double,
        sampleAge: Double
    ) -> PolicyDecision {
        evaluate(snapshot: snapshot, mode: mode, enhancement: 0, now: now, sampleAge: sampleAge)
    }

    public mutating func evaluate(
        snapshot: HardwareSnapshot,
        mode: CoolingMode,
        enhancement: Int,
        now: Double,
        sampleAge: Double
    ) -> PolicyDecision {
        if previousMode != mode {
            reset()
            previousMode = mode
        }

        // A request to restore must work even when sampling or the clock fails.
        if mode == .system {
            return decision(.system, "已选择系统自动；必须交还系统控制。")
        }
        guard Enhancement.isValid(enhancement) else {
            reset()
            previousMode = mode
            return decision(.fault, "温控故障：增强档位不是受支持的 10% 步进值。")
        }

        // A trustworthy alarm field is enough to demand a safety pause, even
        // if another field is invalid. This is not a fallback control temperature.
        let criticalReading = snapshot.temperatures.first { reading in
            (reading.group == "cpu" || reading.group == "gpu")
                && reading.celsius.isFinite
                && (Self.safetyTemperature...120.0).contains(reading.celsius)
        }
        if criticalReading != nil || (2...3).contains(snapshot.thermalPressure) {
            reset()
            previousMode = mode
            let trigger: String
            if let criticalReading {
                trigger = "CPU/GPU 温度达到 90°C（当前 \(criticalReading.celsius)°C）"
            } else {
                trigger = "系统热压力达到 \(snapshot.thermalPressure)（严重或危急）"
            }
            return decision(.system, "安全暂停：\(trigger)；worker 必须交还系统并锁定/暂停，显式恢复前不得重新接管。")
        }

        if let failure = validationFailure(snapshot: snapshot, now: now, sampleAge: sampleAge) {
            // The worker restores and exposes the fault; never retain stale RPMs.
            reset()
            previousMode = mode
            return decision(.fault, "温控故障：\(failure)")
        }
        previousTime = now

        let requiredReadings = snapshot.temperatures.filter { $0.group == "cpu" || $0.group == "gpu" }
        // Validation established that this list contains both required groups.
        // reduce intentionally does not filter invalid values or supply a fallback.
        let temperature = requiredReadings.dropFirst().reduce(requiredReadings[0].celsius) {
            max($0, $1.celsius)
        }

        if mode == .boost {
            let targets = Dictionary(uniqueKeysWithValues: snapshot.fans.map { fan in
                (fan.id, Self.ceiling(fan))
            })
            return PolicyDecision(
                action: .targets,
                targets: targets,
                reason: "强力散热请求 80% 上限转速；worker 必须执行原始 120 秒总期限，续租不得延长。",
                commandedRPM: targets.values.max()
            )
        }

        // While the system still owns the fan its reported target is the baseline
        // this policy enhances, and it is remembered for the whole takeover. Once
        // taken over, the reported target and actual RPM are our own command and
        // must never feed the baseline again, or the step would compound every
        // tick until it reached the ceiling.
        if let fan = snapshot.fans.first, !fan.manual {
            lastSystemTarget = max(fan.minimumRPM, fan.targetRPM, fan.actualRPM)
        }

        if temperature >= Self.entryTemperature {
            coolingDemand = true
        } else if temperature <= Self.exitTemperature {
            coolingDemand = false
        }

        let enhanced = enhancement > 0
        // The baseline is fixed at takeover time and reused unchanged, so the
        // step is applied once to the system's own speed instead of compounding.
        let baseline = enhanced ? Self.baseline(snapshot: snapshot, lastSystemTarget: lastSystemTarget) : nil

        if let start = controlStartedAt {
            let limit = enhanced ? Self.enhancedControlDuration : Self.maximumControlDuration
            if now - start >= limit {
                return release(now: now, reason: enhanced
                    ? "增强接管已满 180 秒；交还系统重新读取基准，至少观察 5 秒。"
                    : "凉爽接管已满 45 秒；交还系统，至少观察 5 秒。")
            }
            if !enhanced {
                if !coolingDemand {
                    return release(now: now, reason: "达到 45°C 舒适偏好退出阈值；交还系统，至少观察 5 秒。")
                }
                let peak = max(peakControlTemperature ?? temperature, temperature)
                peakControlTemperature = peak
                if now - start >= Self.minimumControlDuration,
                   peak - temperature >= Self.releaseTemperatureDrop {
                    return release(now: now, reason: "CPU/GPU 温度较本轮峰值回落至少 2°C，且接管已满 8 秒；不在手动模式降速，交还系统，至少观察 5 秒。")
                }
            }
            guard commandedTargets.count == snapshot.fans.count,
                  snapshot.fans.allSatisfy({ fan in
                      guard let target = commandedTargets[fan.id] else { return false }
                      return target >= fan.minimumRPM && target <= Self.ceiling(fan)
                  }) else {
                reset()
                previousMode = mode
                return decision(.fault, "温控故障：接管期间风扇标识或可用转速范围改变；必须交还系统。")
            }

            guard let desired = desiredTargets(fans: snapshot.fans, temperature: temperature, baseline: baseline, enhancement: enhancement, includeCurve: coolingDemand) else {
                return decision(.hold, "增强基准暂不可用；保持本轮目标，不写更低转速。")
            }
            if snapshot.fans.contains(where: { desired[$0.id]! < commandedTargets[$0.id]! }) {
                // Never write a lower RPM: hold the current target instead. A
                // genuine cooling release is decided above by the 45°C exit,
                // the peak-drop rule and the duration cap.
                return PolicyDecision(action: .hold, targets: [:], reason: enhanced
                    ? "增强目标低于已下发目标；保持原目标，不写更低转速。"
                    : "温度轻微回落或舒适偏好目标降低；保持原目标，不写更低转速，待峰值回落至少 2°C 且接管满 8 秒后交还，上限不变。",
                    baselineRPM: baseline, commandedRPM: commandedTargets.values.max())
            }

            let targets = takeoverTargets(fans: snapshot.fans, desired: desired)
            if targets == commandedTargets {
                return PolicyDecision(action: .hold, targets: [:], reason: enhanced
                    ? "增强目标不变；保持本轮目标，不重复写入，仍受 180 秒上限约束。"
                    : "舒适偏好目标不变；保持本轮目标，不重复写入，仍受 45 秒接管上限约束。",
                    baselineRPM: baseline, commandedRPM: targets.values.max())
            }
            commandedTargets = targets
            return PolicyDecision(action: .targets, targets: targets, reason: enhanced
                ? "按增强档位在系统转速上提速；本轮接管目标只能向上。"
                : "舒适偏好升速；本轮接管目标只能向上。",
                baselineRPM: baseline, commandedRPM: targets.values.max())
        }

        if let start = observationStartedAt {
            guard now - start >= Self.minimumObservationDuration else {
                return decision(.system, "系统观察中；交还后至少 5 秒内不得再次接管。")
            }
            observationStartedAt = nil
        }

        // Without enhancement the original temperature-gated entry is unchanged.
        if !enhanced, !coolingDemand {
            return decision(.system, "未达到 50°C 舒适偏好进入阈值，或已达到 45°C 退出阈值；由系统自动控制。")
        }
        guard let desired = desiredTargets(fans: snapshot.fans, temperature: temperature, baseline: baseline, enhancement: enhancement, includeCurve: coolingDemand) else {
            return decision(.system, "增强基准暂不可用；保持系统自动控制。")
        }

        let targets = takeoverTargets(fans: snapshot.fans, desired: desired)
        controlStartedAt = now
        peakControlTemperature = temperature
        commandedTargets = targets
        return PolicyDecision(
            action: .targets,
            targets: targets,
            reason: enhanced
                ? "按增强档位接管：目标不低于系统当前转速，最多 180 秒，不在手动模式降速。"
                : "按舒适偏好短时接管；初始目标不低于实测/当前目标，最多 45 秒，不在手动模式降速。",
            baselineRPM: baseline,
            commandedRPM: targets.values.max()
        )
    }

    /// The rated maximum is a hardware limit; this app never commands above
    /// `Enhancement.maximumManualFraction` of it, for boost as well.
    static func ceiling(_ fan: FanReading) -> Double {
        max(fan.minimumRPM, fan.maximumRPM * Enhancement.maximumManualFraction)
    }

    /// The speed the system itself was asking for, fixed while this policy owns
    /// the fan. Zero (a stopped fan) is replaced by the validated minimum so a
    /// percentage of it is meaningful. Only the remembered automatic sample is
    /// used — never the live target or actual RPM, which are our own commands
    /// once manual and would make the step compound on every tick.
    static func baseline(snapshot: HardwareSnapshot, lastSystemTarget: Double?) -> Double? {
        guard let fan = snapshot.fans.first else { return nil }
        let remembered = lastSystemTarget ?? fan.minimumRPM
        guard remembered.isFinite, fan.minimumRPM.isFinite else { return nil }
        return max(fan.minimumRPM, remembered)
    }

    /// The comfort curve only participates when there is actual cooling demand.
    /// Without that gate a non-zero enhancement would inherit the curve's 40%
    /// floor even on a cool machine, which is not what the step means.
    private func desiredTargets(fans: [FanReading], temperature: Double, baseline: Double?, enhancement: Int, includeCurve: Bool) -> [Int: Double]? {
        var desired = includeCurve
            ? preferenceTargets(fans: fans, temperature: temperature)
            : Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.minimumRPM) })
        if enhancement > 0 {
            guard let baseline, baseline.isFinite, baseline > 0 else { return nil }
            let factor = 1 + Double(enhancement) / 100
            for fan in fans {
                desired[fan.id] = min(Self.ceiling(fan), max(desired[fan.id]!, baseline * factor))
            }
        }
        return desired
    }

    private func validationFailure(snapshot: HardwareSnapshot, now: Double, sampleAge: Double) -> String? {
        guard now.isFinite, now >= 0 else { return "monotonic 时间必须有限且非负。" }
        if let previousTime, now < previousTime { return "monotonic 时间倒退。" }
        guard sampleAge.isFinite, sampleAge >= 0 else { return "monotonic 样本年龄必须有限且非负。" }
        guard sampleAge <= Self.maximumSampleAge else { return "样本已过期，年龄超过 3 秒。" }
        // sampledAt is metadata only; never subtract it from monotonic now.
        guard snapshot.sampledAt.isFinite else { return "采样时间元数据非有限。" }
        guard snapshot.supported else { return "此硬件或读数能力不受支持。" }
        guard snapshot.issues.isEmpty else { return "硬件报告问题：\(snapshot.issues.joined(separator: "；"))" }
        guard (0...3).contains(snapshot.thermalPressure) else { return "系统热压力不在 0...3 范围。" }
        guard snapshot.temperatures.contains(where: { $0.group == "cpu" }) else { return "缺少 CPU 温度。" }
        guard snapshot.temperatures.contains(where: { $0.group == "gpu" }) else { return "缺少 GPU 温度。" }
        for reading in snapshot.temperatures {
            guard reading.celsius.isFinite else { return "温度 \(reading.name)（\(reading.key)）非有限。" }
            guard (0.0...120.0).contains(reading.celsius) else {
                return "温度 \(reading.name)（\(reading.key)）不在 0...120°C 有效范围。"
            }
        }
        guard !snapshot.fans.isEmpty else { return "没有可用风扇。" }
        var identifiers = Set<Int>()
        for fan in snapshot.fans {
            guard fan.id >= 0, identifiers.insert(fan.id).inserted else { return "风扇标识无效或重复。" }
            guard fan.actualRPM.isFinite, fan.minimumRPM.isFinite,
                  fan.maximumRPM.isFinite, fan.targetRPM.isFinite else {
                return "风扇 \(fan.id) 的转速数据非有限。"
            }
            guard fan.minimumRPM > 0, fan.maximumRPM > fan.minimumRPM else {
                return "风扇 \(fan.id) 的最小/最大转速范围无效。"
            }
            // Above-maximum feedback cannot satisfy both the no-decrease and
            // bounded-target contracts. Restore instead of commanding a decrease.
            guard fan.actualRPM >= 0, fan.actualRPM <= fan.maximumRPM,
                  fan.targetRPM >= 0, fan.targetRPM <= fan.maximumRPM else {
                return "风扇 \(fan.id) 的实测/目标转速为负或超过最大值。"
            }
        }
        return nil
    }

    private func preferenceTargets(fans: [FanReading], temperature: Double) -> [Int: Double] {
        let position = min(1, max(0, (temperature - Self.entryTemperature)
            / (Self.maximumPreferenceTemperature - Self.entryTemperature)))
        let fraction = 0.4 + 0.6 * position
        return Dictionary(uniqueKeysWithValues: fans.map { fan in
            let target = fan.minimumRPM + (fan.maximumRPM - fan.minimumRPM) * fraction
            return (fan.id, min(Self.ceiling(fan), max(fan.minimumRPM, target)))
        })
    }

    private func takeoverTargets(fans: [FanReading], desired: [Int: Double]) -> [Int: Double] {
        Dictionary(uniqueKeysWithValues: fans.map { fan in
            let floor = max(fan.actualRPM, fan.targetRPM, commandedTargets[fan.id] ?? fan.minimumRPM)
            let target = max(desired[fan.id]!, floor)
            return (fan.id, min(Self.ceiling(fan), max(fan.minimumRPM, target)))
        })
    }

    private mutating func release(now: Double, reason: String) -> PolicyDecision {
        controlStartedAt = nil
        peakControlTemperature = nil
        commandedTargets.removeAll()
        observationStartedAt = now
        return decision(.system, reason)
    }

    private func decision(_ action: PolicyAction, _ reason: String) -> PolicyDecision {
        PolicyDecision(action: action, targets: [:], reason: reason)
    }
}
