import AppKit
import SwiftUI

/// Watches only this content region; vertical scrolling remains native.
@MainActor
struct GroupSwipeGesture: NSViewRepresentable {
    var enabled: Bool
    var onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = GestureRegionView()
        context.coordinator.view = view
        context.coordinator.configuration = self
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configuration = self
        if !enabled { context.coordinator.reset() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    private final class GestureRegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var configuration: GroupSwipeGesture?
        private var monitor: Any?
        private var recognizer = GroupSwipeRecognizer()

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            recognizer.reset()
        }

        func reset() { recognizer.reset() }

        private func handle(_ event: NSEvent) -> Bool {
            guard let configuration, configuration.enabled,
                  let view, let window = view.window,
                  window.isKeyWindow, window.isVisible, window.attachedSheet == nil,
                  event.window === window else {
                recognizer.reset()
                return false
            }
            let location = view.convert(event.locationInWindow, from: nil)
            guard !view.isHiddenOrHasHiddenAncestor,
                  view.visibleRect.contains(location) else {
                recognizer.reset()
                return false
            }

            let result: GroupSwipeRecognizer.Result
            if event.type == .swipe {
                result = recognizer.swipe(deltaX: event.deltaX, deltaY: event.deltaY, timestamp: event.timestamp)
            } else {
                // Keep physical swipe direction consistent with either setting
                // of macOS's natural scrolling preference.
                let direction: CGFloat = event.hasPreciseScrollingDeltas && !event.isDirectionInvertedFromDevice ? -1 : 1
                result = recognizer.scroll(
                    deltaX: event.scrollingDeltaX * direction,
                    deltaY: event.scrollingDeltaY,
                    isPrecise: event.hasPreciseScrollingDeltas,
                    phase: phase(event.phase),
                    isMomentum: !event.momentumPhase.isEmpty,
                    timestamp: event.timestamp
                )
            }
            if let direction = result.direction { configuration.onSwipe(direction) }
            return result.consumesEvent
        }

        private func phase(_ phase: NSEvent.Phase) -> GroupSwipeRecognizer.Phase {
            if phase.contains(.cancelled) { return .cancelled }
            if phase.contains(.ended) { return .ended }
            if phase.contains(.began) { return .began }
            if phase.contains(.mayBegin) { return .mayBegin }
            if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
            return .none
        }
    }
}
