import SwiftUI

/// Keeps feedback local to the button so replaying it never changes the row's layout.
@MainActor
struct CopyFeedbackIcon: View {
    var copied: Bool
    var feedbackID: UUID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checkProgress: CGFloat = 0
    @State private var checkScale: CGFloat = 0.65
    @State private var ringScale: CGFloat = 0.65
    @State private var ringOpacity: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(copied ? 0.10 : 0))

            Circle()
                .strokeBorder(Color.green, lineWidth: 1.25)
                .scaleEffect(ringScale)
                .opacity(copied ? ringOpacity : 0)

            Image(systemName: "doc.on.doc")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .opacity(copied ? 0 : 1)

            CopyCheckmark()
                .trim(from: 0, to: checkProgress)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
                .frame(width: 17, height: 17)
                .scaleEffect(checkScale)
                .opacity(copied ? 1 : 0)
        }
        .frame(width: 29, height: 29)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: copied)
        .accessibilityHidden(true)
        .task(id: FeedbackKey(copied: copied, id: feedbackID, reduceMotion: reduceMotion)) {
            await replayFeedback()
        }
    }

    private func replayFeedback() async {
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            checkProgress = copied && !reduceMotion ? 0 : 1
            checkScale = copied && !reduceMotion ? 0.65 : 1
            ringScale = 0.65
            ringOpacity = copied && !reduceMotion ? 0.28 : 0
        }
        guard copied, !reduceMotion else { return }

        // A fresh frame makes the stroke replay even when another click arrives
        // while the previous success check is still visible.
        do {
            try await Task.sleep(nanoseconds: 20_000_000)
        } catch { return }
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.22)) {
            checkProgress = 1
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.60)) {
            checkScale = 1
        }
        withAnimation(.easeOut(duration: 0.46)) {
            ringScale = 1.30
            ringOpacity = 0
        }
    }

    private struct FeedbackKey: Equatable {
        var copied: Bool
        var id: UUID
        var reduceMotion: Bool
    }
}

private struct CopyCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.16, y: rect.height * 0.51))
        path.addLine(to: CGPoint(x: rect.width * 0.41, y: rect.height * 0.76))
        path.addLine(to: CGPoint(x: rect.width * 0.86, y: rect.height * 0.25))
        return path
    }
}
