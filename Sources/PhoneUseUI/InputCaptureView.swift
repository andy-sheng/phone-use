import AppKit
import PhoneUseKit
import SwiftUI

/// Hosts the device screen layer and turns mouse and trackpad input over it into normalized touches.
struct ScreenSurface: NSViewRepresentable {
    let screenLayer: CALayer
    var orientation = DeviceOrientation.portrait
    var acceptsInput = true
    let onTouch: (TouchPhase, CGPoint) -> Void

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
        view.hostedLayer = nil
    }

    private func update(_ view: SurfaceNSView) {
        view.orientation = orientation
        view.hostedLayer = screenLayer
        view.acceptsInput = acceptsInput
        view.onTouch = onTouch
    }

    final class SurfaceNSView: NSView {
        var acceptsInput = true {
            didSet {
                if !acceptsInput { releaseHeldTouch() }
            }
        }
        var onTouch: ((TouchPhase, CGPoint) -> Void)?
        var orientation = DeviceOrientation.portrait {
            didSet {
                guard orientation != oldValue else { return }
                releaseHeldTouch()
                needsLayout = true
            }
        }

        var hostedLayer: CALayer? {
            didSet {
                guard hostedLayer !== oldValue else { return }
                releaseHeldTouch()
                // Switching layouts (such as to the compact window) can hand the layer to a new
                // surface before this one is dismantled; never take it back from that surface.
                if let oldValue, oldValue.superlayer === layer { oldValue.removeFromSuperlayer() }
                if let hostedLayer {
                    layer?.addSublayer(hostedLayer)
                    hostedLayer.setNeedsLayout()
                }
                needsLayout = true
            }
        }

        private var trackpadPan: (center: CGPoint, origin: CGPoint)?
        private var heldPoint: CGPoint?

        func releaseHeldTouch() {
            let point = heldPoint
            heldPoint = nil
            trackpadPan = nil
            if let point { onTouch?(.ended, point) }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            allowedTouchTypes = [.indirect]
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
            guard let hostedLayer, hostedLayer.superlayer === layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer.bounds = CGRect(origin: .zero, size: orientation.isLandscape
                ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
            hostedLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            // The backing layer of this flipped NSView has a downward Y axis.
            hostedLayer.setAffineTransform(CGAffineTransform(rotationAngle: orientation.radians))
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
            guard acceptsInput, trackpadPan == nil, heldPoint != nil else { return }
            let point = normalizedLocation(of: event)
            heldPoint = point
            onTouch?(.moved, point)
        }

        override func mouseUp(with event: NSEvent) {
            guard acceptsInput, trackpadPan == nil, heldPoint != nil else { return }
            onTouch?(.ended, normalizedLocation(of: event))
            heldPoint = nil
        }

        override func scrollWheel(with event: NSEvent) {
            // Even a phased, pixel-precise scroll can come from a mouse thumb wheel.
        }

        override func touchesBegan(with event: NSEvent) {
            guard acceptsInput else { return }
            if trackpadPan != nil { releaseHeldTouch() }
            guard heldPoint == nil, let center = twoFingerCenter(in: event) else { return }
            trackpadPan = (center, normalizedLocation(of: event))
        }

        override func touchesMoved(with event: NSEvent) {
            guard let pan = trackpadPan else { return }
            guard let center = twoFingerCenter(in: event) else {
                releaseHeldTouch()
                return
            }
            let dx = center.x - pan.center.x
            let dy = pan.center.y - center.y // Trackpad Y increases upward; the preview is flipped.
            if heldPoint == nil {
                // A stationary two-finger tap or slight jitter should not tap the device.
                guard hypot(dx, dy) >= 3 else { return }
                onTouch?(.began, pan.origin)
            }
            let point = clamped(CGPoint(x: pan.origin.x + dx / max(bounds.width, 1),
                                        y: pan.origin.y + dy / max(bounds.height, 1)))
            heldPoint = point
            onTouch?(.moved, point)
        }

        override func touchesEnded(with event: NSEvent) {
            if trackpadPan != nil { releaseHeldTouch() }
        }

        override func touchesCancelled(with event: NSEvent) {
            if trackpadPan != nil { releaseHeldTouch() }
        }

        private func twoFingerCenter(in event: NSEvent) -> CGPoint? {
            let touches = event.touches(matching: .touching, in: self)
            guard touches.count == 2, let first = touches.first else { return nil }
            let sum = touches.reduce(CGPoint.zero) { sum, touch in
                CGPoint(x: sum.x + touch.normalizedPosition.x, y: sum.y + touch.normalizedPosition.y)
            }
            return CGPoint(x: sum.x * first.deviceSize.width / 2, y: sum.y * first.deviceSize.height / 2)
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
