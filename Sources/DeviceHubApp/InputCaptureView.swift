import AppKit
import DeviceHubKit
import SwiftUI

/// Hosts the device screen layer and turns mouse and trackpad input over it into normalized touches.
struct ScreenSurface: NSViewRepresentable {
    let screenLayer: CALayer
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

    private func update(_ view: SurfaceNSView) {
        view.hostedLayer = screenLayer
        view.onTouch = onTouch
        view.onFlick = onFlick
    }

    final class SurfaceNSView: NSView {
        var onTouch: ((TouchPhase, CGPoint) -> Void)?
        var onFlick: ((CGPoint, CGVector) -> Void)?
        var hostedLayer: CALayer? {
            didSet {
                guard hostedLayer !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let hostedLayer {
                    layer?.addSublayer(hostedLayer)
                }
                needsLayout = true
            }
        }

        private var scrollOrigin: CGPoint?
        private var scrollOffset = CGVector.zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = bounds
            CATransaction.commit()
        }

        override func mouseDown(with event: NSEvent) {
            onTouch?(.began, normalizedLocation(of: event))
        }

        override func mouseDragged(with event: NSEvent) {
            onTouch?(.moved, normalizedLocation(of: event))
        }

        override func mouseUp(with event: NSEvent) {
            onTouch?(.ended, normalizedLocation(of: event))
        }

        override func scrollWheel(with event: NSEvent) {
            // iOS derives its own momentum from the finger's release velocity.
            guard event.momentumPhase.isEmpty else { return }
            let delta = CGVector(dx: event.scrollingDeltaX / bounds.width, dy: event.scrollingDeltaY / bounds.height)

            guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else {
                let scale = 12.0
                onFlick?(normalizedLocation(of: event), CGVector(dx: delta.dx * scale, dy: delta.dy * scale))
                return
            }

            if event.phase.contains(.began) {
                let origin = normalizedLocation(of: event)
                scrollOrigin = origin
                scrollOffset = .zero
                onTouch?(.began, origin)
            }
            guard let origin = scrollOrigin else { return }
            scrollOffset.dx += delta.dx
            scrollOffset.dy += delta.dy
            let point = CGPoint(x: origin.x + scrollOffset.dx, y: origin.y + scrollOffset.dy)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                onTouch?(.ended, point)
                scrollOrigin = nil
            } else if event.phase.contains(.changed) {
                onTouch?(.moved, point)
            }
        }

        private func normalizedLocation(of event: NSEvent) -> CGPoint {
            let location = convert(event.locationInWindow, from: nil)
            return CGPoint(x: location.x / max(bounds.width, 1), y: location.y / max(bounds.height, 1))
        }
    }
}
