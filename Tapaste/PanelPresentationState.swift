/// A generation belongs to exactly one opening or closing transition. An old
/// animation completion must never hide a panel that has since opened again.
struct PanelPresentationState {
    enum Phase { case hidden, appearing, visible, disappearing }
    private(set) var phase = Phase.hidden
    private(set) var generation: UInt64 = 0

    var wantsVisible: Bool { phase == .appearing || phase == .visible }

    mutating func beginShow() -> UInt64? {
        guard !wantsVisible else { return nil }
        generation &+= 1
        phase = .appearing
        return generation
    }

    mutating func beginDismiss() -> UInt64? {
        guard wantsVisible else { return nil }
        generation &+= 1
        phase = .disappearing
        return generation
    }

    @discardableResult
    mutating func finishShow(_ token: UInt64) -> Bool {
        guard generation == token, phase == .appearing else { return false }
        phase = .visible
        return true
    }

    @discardableResult
    mutating func finishDismiss(_ token: UInt64) -> Bool {
        guard generation == token, phase == .disappearing else { return false }
        phase = .hidden
        return true
    }
}
