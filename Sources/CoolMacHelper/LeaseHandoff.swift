import CoolMacCore

enum LeaseHandoff {
    typealias State = (mode: CoolingMode, until: Double, session: String?)

    static func receive(phase: ControlPhase, commissioningCompleted: Bool, current: State) -> State {
        if phase == .fault { return (.system, 0, nil) }
        return (commissioningCompleted ? .system : current.mode, current.until, current.session)
    }
}
