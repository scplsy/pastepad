import AppKit
import QuartzCore
import SwiftUI

struct NativeGroupSegment: Equatable, Identifiable {
    var id: String
    var title: String
    var systemImage: String? = nil
    var isCustomGroup = false
}

enum NativeGroupContextAction: String {
    case newItem
    case rename
    case delete
}

/// AppKit owns the bezel, selection feedback, keyboard navigation and accessibility.
/// Keep this control alive when the selected page changes so its native transition survives.
@MainActor
struct NativeGroupTabs: NSViewRepresentable {
    var segments: [NativeGroupSegment]
    var selection: String
    var onSelect: (String) -> Void
    var onContextAction: (String, NativeGroupContextAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    func makeNSView(context: Context) -> GroupSegmentedControl {
        let control = GroupSegmentedControl()
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        control.segmentDistribution = .fit
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectSegment(_:))
        control.setAccessibilityLabel(L("Clipboard groups", "剪贴板分组"))
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        if #available(macOS 27.0, *) {
            control.role = .tabs
        }
        control.contextMenuProvider = { [weak coordinator = context.coordinator] index in
            coordinator?.contextMenu(for: index)
        }
        context.coordinator.update(control, configuration: self)
        return control
    }

    func updateNSView(_ control: GroupSegmentedControl, context: Context) {
        context.coordinator.update(control, configuration: self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GroupSegmentedControl, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    @MainActor
    final class Coordinator: NSObject {
        private var configuration: NativeGroupTabs
        private var renderedSegments: [NativeGroupSegment] = []
        private var revealGeneration = 0

        init(configuration: NativeGroupTabs) {
            self.configuration = configuration
        }

        func update(_ control: GroupSegmentedControl, configuration: NativeGroupTabs) {
            let selectionChanged = self.configuration.selection != configuration.selection
            self.configuration = configuration
            let structureChanged = renderedSegments != configuration.segments
            if structureChanged {
                renderedSegments = configuration.segments
                control.segmentCount = renderedSegments.count
                for (index, segment) in renderedSegments.enumerated() {
                    control.setLabel(segment.title, forSegment: index)
                    control.setToolTip(segment.title, forSegment: index)
                    control.setWidth(0, forSegment: index)
                    control.setTag(index, forSegment: index)
                    let image = segment.systemImage.flatMap {
                        NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
                    }
                    control.setImage(image, forSegment: index)
                    control.setImageScaling(.scaleProportionallyDown, forSegment: index)
                    control.setShowsMenuIndicator(false, forSegment: index)
                }
                control.invalidateIntrinsicContentSize()
            }

            let index = renderedSegments.firstIndex { $0.id == configuration.selection } ?? -1
            let nativeSelectionChanged = control.selectedSegment != index
            if nativeSelectionChanged {
                // AppKit applies the native selection feedback. Scrolling has
                // its own animation instead of inheriting SwiftUI's page spring.
                control.selectedSegment = index
            }
            if structureChanged || selectionChanged || nativeSelectionChanged {
                scheduleReveal(control, index: index, animated: !structureChanged)
            }
        }

        @objc func selectSegment(_ sender: NSSegmentedControl) {
            guard renderedSegments.indices.contains(sender.selectedSegment) else { return }
            if let control = sender as? GroupSegmentedControl {
                scheduleReveal(control, index: sender.selectedSegment, animated: true)
            }
            configuration.onSelect(renderedSegments[sender.selectedSegment].id)
        }

        private func scheduleReveal(_ control: GroupSegmentedControl, index: Int, animated: Bool) {
            revealGeneration += 1
            guard renderedSegments.indices.contains(index) else { return }
            let generation = revealGeneration
            let id = renderedSegments[index].id
            // Wait for updated label widths/layout, coalescing the native click
            // and the following SwiftUI update into one reveal.
            DispatchQueue.main.async { [weak self, weak control] in
                guard let self, let control, self.revealGeneration == generation,
                      self.renderedSegments.indices.contains(index),
                      self.renderedSegments[index].id == id,
                      control.selectedSegment == index else { return }
                control.revealSegment(index, animated: animated)
            }
        }

        func contextMenu(for index: Int) -> NSMenu? {
            guard renderedSegments.indices.contains(index), renderedSegments[index].isCustomGroup else { return nil }
            let segment = renderedSegments[index]
            let menu = NSMenu()
            menu.addItem(menuItem(L("New item in this group…", "在此分组新建条目…"), groupID: segment.id, action: .newItem))
            menu.addItem(.separator())
            menu.addItem(menuItem(L("Rename group…", "重命名分组…"), groupID: segment.id, action: .rename))
            menu.addItem(menuItem(L("Delete group…", "删除分组…"), groupID: segment.id, action: .delete))
            return menu
        }

        private func menuItem(_ title: String, groupID: String, action: NativeGroupContextAction) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(performContextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [groupID, action.rawValue]
            return item
        }

        @objc private func performContextAction(_ sender: NSMenuItem) {
            guard let values = sender.representedObject as? [String], values.count == 2,
                  let action = NativeGroupContextAction(rawValue: values[1]),
                  configuration.segments.contains(where: { $0.id == values[0] && $0.isCustomGroup }) else { return }
            configuration.onContextAction(values[0], action)
        }
    }
}

@MainActor
final class GroupSegmentedControl: NSSegmentedControl {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        guard let index = segmentFrames.firstIndex(where: { $0.contains(screenPoint) }) else { return nil }
        return contextMenuProvider?(index)
    }

    func revealSegment(_ index: Int, animated: Bool) {
        let frames = segmentFrames
        guard let window, frames.indices.contains(index),
              let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let windowRect = window.convertFromScreen(frames[index])
        let target = clipView.convert(windowRect, from: nil).insetBy(dx: -8, dy: 0)
        let visible = clipView.bounds
        guard visible.width > 0 else { return }
        var proposed = visible
        if target.width > visible.width {
            proposed.origin.x = target.midX - visible.width / 2
        } else if target.minX < visible.minX {
            proposed.origin.x = target.minX
        } else if target.maxX > visible.maxX {
            proposed.origin.x = target.maxX - visible.width
        } else {
            return
        }
        let destination = clipView.constrainBoundsRect(proposed).origin
        guard abs(destination.x - visible.origin.x) > 0.5 else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.22
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animation.allowsImplicitAnimation = false
                clipView.animator().setBoundsOrigin(destination)
            }
        } else {
            clipView.scroll(to: destination)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    // AppKit exposes the exact native segment bounds, including appearance-dependent spacing.
    // Using these avoids guessing at text widths or drawing private segment geometry.
    private var segmentFrames: [NSRect] {
        let frames = leafFrames(in: self)
        return frames.count == segmentCount ? frames : []
    }

    private func leafFrames(in element: any NSAccessibilityProtocol) -> [NSRect] {
        let children = (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        guard !children.isEmpty else { return [element.accessibilityFrame()] }
        // NSSegmentedControl exposes its cell first; the cell exposes the segments.
        return children.flatMap { leafFrames(in: $0) }
    }
}
