import Foundation
import Darwin

@main
struct GroupSwipeTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    private static func event(_ recognizer: inout GroupSwipeRecognizer, _ x: CGFloat, _ y: CGFloat = 0,
                              phase: GroupSwipeRecognizer.Phase = .changed, time: TimeInterval = 1,
                              precise: Bool = true, momentum: Bool = false) -> GroupSwipeRecognizer.Result {
        recognizer.scroll(deltaX: x, deltaY: y, isPrecise: precise, phase: phase, isMomentum: momentum, timestamp: time)
    }

    private static func run() throws {
        do {
            var r = GroupSwipeRecognizer()
            try expect(event(&r, -24, phase: .began).direction == nil, "A half gesture must not navigate.")
            try expect(event(&r, -24, time: 1.05).direction == 1, "48px left must select the next group.")
            try expect(event(&r, -200, time: 1.1).direction == nil, "A gesture must navigate at most once.")
            try expect(event(&r, -200, time: 3).direction == nil, "Pausing with fingers down must not rearm a gesture.")
            _ = event(&r, 0, phase: .ended, time: 3.1)
            try expect(event(&r, 48, phase: .began, time: 3.15).direction == -1, "A new right gesture must immediately select the previous group.")
            print("PASS: Precise threshold and one navigation per physical gesture.")
        }
        do {
            var r = GroupSwipeRecognizer()
            let first = event(&r, 1, 12, phase: .began)
            let diagonal = event(&r, -100, 2, time: 1.05)
            try expect(!first.consumesEvent && !diagonal.consumesEvent && diagonal.direction == nil,
                       "A vertical gesture must remain vertical even after horizontal drift.")
            print("PASS: Vertical scrolling and diagonal drift remain untouched.")
        }
        do {
            var r = GroupSwipeRecognizer()
            _ = event(&r, -20, phase: .began)
            try expect(event(&r, 20, time: 1.05).direction == nil, "Reversal before threshold must not navigate.")
            _ = event(&r, 0, phase: .cancelled, time: 1.1)
            try expect(event(&r, -28, phase: .began, time: 1.2).direction == nil, "Cancellation must reset accumulated distance.")
            try expect(event(&r, -200, time: 1.3, momentum: true).direction == nil, "Momentum must never trigger navigation.")
            print("PASS: Reversal, cancellation, and momentum cannot trigger accidental group changes.")
        }
        do {
            var r = GroupSwipeRecognizer()
            try expect(event(&r, -2, phase: .none, precise: false).direction == 1, "A horizontal wheel tick must navigate.")
            try expect(event(&r, -2, phase: .none, time: 1.1, precise: false).direction == nil, "Wheel bursts require a cooldown.")
            try expect(event(&r, 2, phase: .none, time: 1.4, precise: false).direction == -1, "The wheel must navigate after its cooldown.")
            try expect(!event(&r, 1, 10, phase: .none, time: 2, precise: false).consumesEvent, "Vertical wheel events must pass through.")
            print("PASS: Horizontal wheel cooldown preserves ordinary vertical wheel events.")
        }
        do {
            var r = GroupSwipeRecognizer()
            try expect(r.swipe(deltaX: 1, deltaY: 0, timestamp: 1).direction == 1, "Native discrete left swipe must navigate next.")
            try expect(r.swipe(deltaX: -1, deltaY: 0, timestamp: 1.4).direction == -1, "Native discrete right swipe must navigate previous.")
            try expect(!r.swipe(deltaX: 0, deltaY: 1, timestamp: 2).consumesEvent, "Vertical discrete swipes must pass through.")
            _ = event(&r, -48, phase: .began, time: 3)
            try expect(r.swipe(deltaX: 1, deltaY: 0, timestamp: 3.05).direction == nil, "A discrete duplicate of a scroll gesture must not double-navigate.")
            print("PASS: Discrete swipe directions and duplicate suppression.")
        }
        do {
            var natural = GroupSwipeRecognizer(), reversed = GroupSwipeRecognizer()
            let naturalPhysicalLeft: CGFloat = -48
            let nonNaturalPhysicalLeft: CGFloat = 48
            try expect(event(&natural, naturalPhysicalLeft, phase: .began).direction ==
                       event(&reversed, nonNaturalPhysicalLeft * -1, phase: .began).direction,
                       "Natural-scroll normalization must preserve the same physical swipe direction.")
            natural.reset()
            try expect(event(&natural, -24, phase: .began, time: 2).direction == nil, "Disabling or leaving the content region must clear old distance.")
            print("PASS: Direction normalization and explicit reset.")
        }
        print("All 6 group swipe checks passed.")
    }
}
