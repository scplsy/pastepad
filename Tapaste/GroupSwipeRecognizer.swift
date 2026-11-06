import Foundation

/// Turns a deliberate horizontal gesture into at most one group change.
/// It keeps vertical gestures untouched and never treats momentum as a new swipe.
struct GroupSwipeRecognizer {
    enum Phase { case none, mayBegin, began, changed, ended, cancelled }
    struct Result {
        var direction: Int?
        var consumesEvent: Bool
        static let ignored = Result(direction: nil, consumesEvent: false)
    }

    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var fired = false
    private var lastNavigationTime = -Double.infinity
    private var lastWheelTime = -Double.infinity

    mutating func reset() {
        resetGesture()
        lastNavigationTime = -Double.infinity
        lastWheelTime = -Double.infinity
    }

    mutating func scroll(deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool, phase: Phase,
                         isMomentum: Bool, timestamp: TimeInterval) -> Result {
        if isMomentum {
            return Result(direction: nil, consumesEvent: axis == .horizontal)
        }
        if !isPrecise || phase == .none {
            return wheel(deltaX: deltaX, deltaY: deltaY, timestamp: timestamp)
        }
        if phase == .mayBegin || phase == .began {
            resetGesture()
        }
        if phase == .ended || phase == .cancelled {
            let consumed = axis == .horizontal
            resetGesture()
            return Result(direction: nil, consumesEvent: consumed)
        }

        accumulatedX += deltaX
        accumulatedY += deltaY
        if axis == .undecided {
            let x = abs(accumulatedX), y = abs(accumulatedY)
            if x >= 8 && x > y * 1.25 { axis = .horizontal }
            else if y >= 8 && y > x * 1.25 { axis = .vertical }
        }
        guard axis == .horizontal else { return .ignored }
        guard !fired, abs(accumulatedX) >= 48 else {
            return Result(direction: nil, consumesEvent: true)
        }
        fired = true
        lastNavigationTime = timestamp
        // Negative normalized scrolling follows a physical left swipe: next.
        return Result(direction: accumulatedX < 0 ? 1 : -1, consumesEvent: true)
    }

    mutating func swipe(deltaX: CGFloat, deltaY: CGFloat, timestamp: TimeInterval) -> Result {
        guard abs(deltaX) > abs(deltaY), deltaX != 0 else { return .ignored }
        guard timestamp - lastNavigationTime >= 0.25 else {
            return Result(direction: nil, consumesEvent: true)
        }
        lastNavigationTime = timestamp
        // NSEvent.swipe uses +1 for left and -1 for right.
        return Result(direction: deltaX > 0 ? 1 : -1, consumesEvent: true)
    }

    private mutating func wheel(deltaX: CGFloat, deltaY: CGFloat, timestamp: TimeInterval) -> Result {
        guard abs(deltaX) > abs(deltaY) * 1.25, deltaX != 0 else { return .ignored }
        guard timestamp - lastWheelTime >= 0.32 else {
            return Result(direction: nil, consumesEvent: true)
        }
        lastWheelTime = timestamp
        lastNavigationTime = timestamp
        return Result(direction: deltaX < 0 ? 1 : -1, consumesEvent: true)
    }

    private mutating func resetGesture() {
        axis = .undecided
        accumulatedX = 0
        accumulatedY = 0
        fired = false
    }
}
