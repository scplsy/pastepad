import AppKit
import SwiftUI

/// Uses the system material, including its accessibility and appearance settings.
@MainActor
struct GlassSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                SystemMaterial()
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

@MainActor
private struct SystemMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 20
        material.layer?.masksToBounds = true
        return material
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
