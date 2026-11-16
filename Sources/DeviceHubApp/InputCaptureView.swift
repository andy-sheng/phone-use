import AppKit
import DeviceHubKit
import SwiftUI

/// Hosts the device screen layer and turns mouse and trackpad input over it into normalized touches.
struct ScreenSurface: NSViewRepresentable {
    let screenLayer: CALayer
    var acceptsInput = true
    let onTouch: (TouchPhase, CGPoint) -> Void
    let onFlick: (CGPoint, CGVector) -> Void

    func makeNSView(context: Context) -> SurfaceNSView {
        let view = SurfaceNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: SurfaceNSView, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: SurfaceNSView, coordinator: ()) {
        view.releaseHeldTouch()
        view.onTouch = nil
        view.onFlick = nil
        view.hostedLayer = nil
    }

    private func update(_ view: SurfaceNSView) {
        view.hostedLayer = screenLayer
        view.acceptsInput = acceptsInput
        view.onTouch = onTouch
        view.onFlick = onFlick
    }

    final class SurfaceNSView: NSView {
        var acceptsInput = true {
            didSet {
                if !acceptsInput { releaseHeldTouch() }
            }
        }
        var onTouch: ((TouchPhase, CGPoint) -> Void)?
        var onFlick: ((CGPoint, CGVector) -> Void)?
        var hostedLayer: CALayer? {
            didSet {
                guard hostedLayer !== oldValue else { return }
                releaseHeldTouch()
                // Switching layouts (such as to the compact window) can hand the layer to a new
                // surface before this one is dismantled; never take it back from that surface.
                if let oldValue, oldValue.superlayer === layer { oldValue.removeFromSuperlayer() }
                if let hostedLayer {
                    layer?.addSublayer(hostedLayer)
                }
                needsLayout = true
            }
        }

        private var scrollOrigin: CGPoint?
        private var heldPoint: CGPoint?
        private var scrollOffset = CGVector.zero

        func releaseHeldTouch() {
            let point = heldPoint
            heldPoint = nil
            scrollOrigin = nil
            scrollOffset = .zero
            if let point { onTouch?(.ended, point) }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { acceptsInput }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsInput }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = bounds
            CATransaction.commit()
        }

        override func mouseDown(with event: NSEvent) {
            guard acceptsInput else { return }
            releaseHeldTouch()
            let point = normalizedLocation(of: event)
            heldPoint = point
            onTouch?(.began, point)
        }

        override func mouseDragged(with event: NSEvent) {
            guard acceptsInput, heldPoint != nil else { return }
            let point = normalizedLocation(of: event)
            heldPoint = point
            onTouch?(.moved, point)
        }

        override func mouseUp(with event: NSEvent) {
            guard acceptsInput, heldPoint != nil else { return }
            onTouch?(.ended, normalizedLocation(of: event))
            heldPoint = nil
        }

        override func scrollWheel(with event: NSEvent) {
            guard acceptsInput else { return }
            // iOS derives its own momentum from the finger's release velocity.
            guard event.momentumPhase.isEmpty else { return }
            let delta = CGVector(dx: event.scrollingDeltaX / max(bounds.width, 1),
                                 dy: event.scrollingDeltaY / max(bounds.height, 1))

            guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else {
                let scale = 12.0
                onFlick?(normalizedLocation(of: event), CGVector(dx: delta.dx * scale, dy: delta.dy * scale))
                return
            }

            if event.phase.contains(.began) {
                releaseHeldTouch()
                let origin = normalizedLocation(of: event)
                scrollOrigin = origin
                heldPoint = origin
                scrollOffset = .zero
                onTouch?(.began, origin)
            }
            guard let origin = scrollOrigin else { return }
            scrollOffset.dx += delta.dx
            scrollOffset.dy += delta.dy
            let point = clamped(CGPoint(x: origin.x + scrollOffset.dx, y: origin.y + scrollOffset.dy))
            heldPoint = point
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                onTouch?(.ended, point)
                scrollOrigin = nil
                heldPoint = nil
            } else if event.phase.contains(.changed) {
                onTouch?(.moved, point)
            }
        }

        private func normalizedLocation(of event: NSEvent) -> CGPoint {
            let location = convert(event.locationInWindow, from: nil)
            return clamped(CGPoint(x: location.x / max(bounds.width, 1), y: location.y / max(bounds.height, 1)))
        }

        private func clamped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        }
    }
}
