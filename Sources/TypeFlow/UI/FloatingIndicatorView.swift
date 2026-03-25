import AppKit
import SwiftUI

// MARK: - SwiftUI Content

private struct IndicatorContentView: View {
    let phase: AppPhase

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

            content
        }
        .frame(width: 60, height: 60)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .recording:
            RecordingIndicator()
        case .processing:
            ProcessingIndicator()
        case .error:
            ErrorIndicator()
        case .idle:
            EmptyView()
        }
    }
}

private struct RecordingIndicator: View {
    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.red.opacity(0.3), lineWidth: 2.5)
                .frame(width: 46, height: 46)
                .scaleEffect(scale)

            Image(systemName: "mic.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.red)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                scale = 1.2
            }
        }
    }
}

private struct ProcessingIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 32, height: 32)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

private struct ErrorIndicator: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 22))
            .foregroundStyle(.orange)
    }
}

// MARK: - NSPanel Controller

@MainActor
final class FloatingIndicator {
    private var panel: NSPanel?
    private var moveObserver: (any NSObjectProtocol)?

    func show(phase: AppPhase) {
        ensurePanel()
        let content = IndicatorContentView(phase: phase)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 60, height: 60)
        panel?.contentView = hosting
        if !(panel?.isVisible ?? false) {
            panel?.orderFront(nil)
        }
    }

    func hide() {
        savePosition()
        panel?.orderOut(nil)
    }

    private func savePosition() {
        guard let origin = panel?.frame.origin else { return }
        ConfigManager.shared.indicatorPosition = (Double(origin.x), Double(origin.y))
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.isMovableByWindowBackground = true

        // Position: saved or default (bottom-center)
        if let saved = ConfigManager.shared.indicatorPosition {
            p.setFrameOrigin(NSPoint(x: saved.x, y: saved.y))
        } else if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vis.midX - 30, y: vis.minY + 20))
        }

        panel = p

        // Save position after drag
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.savePosition()
            }
        }
    }
}
