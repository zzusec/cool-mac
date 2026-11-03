/// What the durable state left behind by the previous control session means for
/// the next one.
///
/// The ownership journal is rewritten on every control step, so it outlives any
/// termination that skips the shutdown handshake: a system shutdown, an OS
/// upgrade, a power loss or a SIGKILL. A leftover journal is therefore not
/// evidence of a control failure. Releasing the fans and verifying the readback
/// is the whole recovery, so only a fault the failing session actually recorded
/// keeps the takeover lock.
public enum StartupJournal {
    public enum Condition: Equatable, Sendable {
        /// Nothing durable was left behind.
        case clean
        /// Ownership was left behind without a recorded fault.
        case interrupted
        /// A previous session recorded a control fault.
        case faulted
    }

    public static func condition(hasOwnershipJournal: Bool, hasRecordedFault: Bool) -> Condition {
        if hasRecordedFault { return .faulted }
        return hasOwnershipJournal ? .interrupted : .clean
    }

    public static func phaseAfterRestore(hasRecordedFault: Bool) -> ControlPhase {
        hasRecordedFault ? .fault : .system
    }

    /// Reported once an interrupted session's ownership has been released.
    public static let interruptedMessage = "上次控制被系统中断，已恢复系统自动"

    /// A latched fault keeps the reason its session recorded, so the operator
    /// can tell a real control failure from a handshake that was cut short.
    public static func faultMessage(recorded: String?) -> String {
        let fallback = "上次控制发生故障；已停止接管，请先恢复再重新安全自检"
        guard let recorded else { return fallback }
        let reason = recorded
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !reason.isEmpty else { return fallback }
        return "上次控制发生故障：\(reason.prefix(160))；请先恢复再重新安全自检"
    }
}
