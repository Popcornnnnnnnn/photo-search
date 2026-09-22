@preconcurrency import AppKit
import SwiftUI

struct TrackpadPagingGestureState {
    private(set) var accumulatedX: CGFloat = 0

    mutating func begin() {
        accumulatedX = 0
    }

    mutating func consume(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat? {
        guard abs(deltaX) > abs(deltaY) * 1.15 else { return nil }
        accumulatedX += deltaX
        return accumulatedX
    }
}

struct TrackpadPagingObserver: NSViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    func makeNSView(context: Context) -> TrackpadPagingCaptureView {
        let view = TrackpadPagingCaptureView()
        view.onWindowFrameChange = context.coordinator.updateWindowFrame
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: TrackpadPagingCaptureView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        nsView.publishWindowFrame()
    }

    static func dismantleNSView(_ nsView: TrackpadPagingCaptureView,
                                coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onChanged: (CGFloat) -> Void
        var onEnded: () -> Void

        private var observedWindowNumber: Int?
        private var observedFrame: CGRect = .zero
        private var monitor: Any?
        private var gesture = TrackpadPagingGestureState()

        init(onChanged: @escaping (CGFloat) -> Void,
             onEnded: @escaping () -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach(to view: TrackpadPagingCaptureView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
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

        private func handle(_ event: NSEvent) -> NSEvent {
            guard event.hasPreciseScrollingDeltas,
                  !event.phase.isEmpty,
                  event.momentumPhase.isEmpty,
                  event.windowNumber == observedWindowNumber,
                  observedFrame.contains(event.locationInWindow) else {
                return event
            }

            if event.phase.contains(.began) {
                gesture.begin()
                onChanged(0)
            }

            // Keep paging aligned with Photos: pushing two fingers left reveals
            // the next photo, while pushing right reveals the previous photo.
            let directionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            if let translation = gesture.consume(
                deltaX: event.scrollingDeltaX * directionMultiplier,
                deltaY: event.scrollingDeltaY * directionMultiplier
            ) {
                onChanged(translation)
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                onEnded()
                gesture.begin()
            }
            return event
        }
    }
}

final class TrackpadPagingCaptureView: NSView {
    var onWindowFrameChange: ((Int, CGRect) -> Void)?

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
