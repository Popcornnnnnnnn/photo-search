@preconcurrency import AppKit
import SwiftUI

/// A subtle click ripple. The AppKit observer watches local mouse-down events
/// without taking part in hit testing, so existing controls keep their normal
/// click and drag behavior without continuous mouse-move redraws.
struct PointerEffectsOverlay: View {
    let reduceMotion: Bool

    @State private var ripples: [PointerRipple] = []

    var body: some View {
        GeometryReader { _ in
            ZStack {
                ForEach(ripples) { ripple in
                    PointerRippleView(
                        position: ripple.position,
                        reduceMotion: reduceMotion
                    )
                }

                PointerEventObserver(
                    onClick: addRipple
                )
            }
            .clipped()
        }
        .accessibilityHidden(true)
    }

    private func addRipple(at position: CGPoint) {
        let ripple = PointerRipple(position: position)
        ripples.append(ripple)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 180 : 500))
            ripples.removeAll { $0.id == ripple.id }
        }
    }
}

private struct PointerRipple: Identifiable {
    let id = UUID()
    let position: CGPoint
}

private struct PointerRippleView: View {
    @Environment(ThemeStore.self) private var theme

    let position: CGPoint
    let reduceMotion: Bool

    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.accent.opacity(0.065))
            Circle()
                .stroke(theme.accent.opacity(0.34), lineWidth: 1)
        }
        .frame(width: reduceMotion ? 20 : 46, height: reduceMotion ? 20 : 46)
        .scaleEffect(expanded ? 1 : 0.18)
        .opacity(expanded ? 0 : 0.64)
        .position(position)
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.14 : 0.44)) {
                expanded = true
            }
        }
    }
}

private struct PointerEventObserver: NSViewRepresentable {
    let onClick: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClick: onClick)
    }

    func makeNSView(context: Context) -> PointerCaptureView {
        let view = PointerCaptureView()
        view.onWindowFrameChange = context.coordinator.updateWindowFrame
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: PointerCaptureView, context: Context) {
        context.coordinator.onClick = onClick
        nsView.publishWindowFrame()
    }

    static func dismantleNSView(_ nsView: PointerCaptureView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onClick: (CGPoint) -> Void

        private var observedWindowNumber: Int?
        private var observedFrame: CGRect = .zero
        private var monitor: Any?

        init(onClick: @escaping (CGPoint) -> Void) {
            self.onClick = onClick
        }

        func attach(to view: PointerCaptureView) {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                guard let self,
                      event.windowNumber == self.observedWindowNumber else { return event }

                let windowPosition = event.locationInWindow
                guard self.observedFrame.contains(windowPosition) else { return event }
                let position = CGPoint(
                    x: windowPosition.x - self.observedFrame.minX,
                    y: self.observedFrame.maxY - windowPosition.y
                )

                self.onClick(position)
                return event
            }
        }

        func updateWindowFrame(_ windowNumber: Int, _ frame: CGRect) {
            observedWindowNumber = windowNumber
            observedFrame = frame
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            detach()
        }
    }
}

private final class PointerCaptureView: NSView {
    var onWindowFrameChange: ((Int, CGRect) -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishWindowFrame()
    }

    override func layout() {
        super.layout()
        publishWindowFrame()
    }

    func publishWindowFrame() {
        guard let window else { return }
        onWindowFrameChange?(window.windowNumber, convert(bounds, to: nil))
    }
}
