import Foundation
import Darwin

@main
struct PanelPresentationTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    private static func run() throws {
        do {
            var state = PanelPresentationState()
            let opening = state.beginShow()!
            let closing = state.beginDismiss()!
            try expect(!state.finishShow(opening), "A delayed opening completion must not undo a newer dismissal.")
            try expect(state.finishDismiss(closing) && state.phase == .hidden, "The latest dismissal must finish normally.")
            print("PASS: Dismissing during opening ignores the old opening completion.")
        }
        do {
            var state = PanelPresentationState()
            _ = state.beginShow()
            let closing = state.beginDismiss()!
            let reopening = state.beginShow()!
            try expect(!state.finishDismiss(closing), "An old dismissal must not order out a reopened panel.")
            try expect(state.finishShow(reopening) && state.phase == .visible, "The reopened panel must remain visible.")
            print("PASS: Reopening during dismissal ignores the old order-out completion.")
        }
        do {
            var state = PanelPresentationState()
            let opening = state.beginShow()!
            try expect(state.beginShow() == nil && state.generation == opening, "A reopen request for a visible session must preserve its identity.")
            _ = state.beginDismiss()
            let generation = state.generation
            try expect(state.beginDismiss() == nil && state.generation == generation, "A second resign-key dismissal must not start another transition.")
            print("PASS: Duplicate show/dismiss requests preserve the active transition.")
        }
        do {
            var state = PanelPresentationState()
            _ = state.beginShow()
            let deferredResignGeneration = state.generation
            _ = state.beginDismiss()
            _ = state.beginShow()
            try expect(state.generation != deferredResignGeneration && state.wantsVisible,
                       "A queued focus-loss handler must be stale after a close/reopen cycle.")
            print("PASS: A queued resign-key event cannot dismiss a newer presentation.")
        }
        do {
            var state = PanelPresentationState()
            var completions: [(UInt64, Bool)] = []
            for _ in 0..<101 {
                if state.wantsVisible { completions.append((state.beginDismiss()!, false)) }
                else { completions.append((state.beginShow()!, true)) }
            }
            for (token, opening) in completions.reversed() {
                if opening { state.finishShow(token) }
                else { state.finishDismiss(token) }
            }
            try expect(state.phase == .visible, "Rapid toggles must follow the final intent despite reversed completion order.")
            print("PASS: 101 rapid toggles remain visible after out-of-order animation completions.")
        }
        print("All 5 panel presentation checks passed.")
    }
}
