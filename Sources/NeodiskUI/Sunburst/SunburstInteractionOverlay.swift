//
//  SunburstInteractionOverlay.swift
//  Neodisk
//
//  AppKit event layer over the sunburst: tracking-area hover, click vs pan
//  disambiguation (3 pt threshold), pinch and ⌘/⌥-scroll zoom, two-finger
//  pan while zoomed, tooltips, and the right-click context menu. Ported
//  from Radix minus its drag-to-discard support (Neodisk is read-only).
//

import AppKit
import SwiftUI

struct SunburstInteractionOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void
    let onPan: (CGSize) -> Void
    let onMagnify: (CGPoint, CGFloat) -> Void
    let canStartPan: (CGPoint) -> Bool
    let contextMenu: (CGPoint) -> NSMenu?
    let help: (CGPoint) -> String?
    let isPanEnabled: Bool

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: InteractionView) {
        view.onHover = onHover
        view.onClick = onClick
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.canStartPan = canStartPan
        view.contextMenu = contextMenu
        view.help = help
        view.isPanEnabled = isPanEnabled
    }

    final class InteractionView: NSView {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint, Int) -> Void = { _, _ in }
        var onPan: (CGSize) -> Void = { _ in }
        var onMagnify: (CGPoint, CGFloat) -> Void = { _, _ in }
        var canStartPan: (CGPoint) -> Bool = { _ in false }
        var contextMenu: (CGPoint) -> NSMenu? = { _ in nil }
        var help: (CGPoint) -> String? = { _ in nil }
        var isPanEnabled = false

        private static let dragThreshold: CGFloat = 3
        private static let lineScrollScale: CGFloat = 10
        fileprivate nonisolated static let maximumScrollPanDelta: CGFloat = 80
        private var trackingArea: NSTrackingArea?
        private var mouseDownLocation: CGPoint?
        private var lastDragLocation: CGPoint?
        private var shouldPanFromMouseDownLocation = false
        private var didPan = false

        override var isFlipped: Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            self.trackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            updatePointerFeedback(at: eventLocation(event))
        }

        override func mouseMoved(with event: NSEvent) {
            updatePointerFeedback(at: eventLocation(event))
        }

        override func mouseExited(with event: NSEvent) {
            onHover(nil)
            toolTip = nil
        }

        override func mouseDown(with event: NSEvent) {
            let location = eventLocation(event)
            mouseDownLocation = location
            lastDragLocation = location
            shouldPanFromMouseDownLocation = isPanEnabled && canStartPan(location)
            didPan = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownLocation,
                  let lastDragLocation else { return }

            let location = eventLocation(event)
            if !didPan {
                guard didExceedDragThreshold(from: mouseDownLocation, to: location) else {
                    return
                }
                didPan = true
            }

            defer { self.lastDragLocation = location }
            guard shouldPanFromMouseDownLocation, isPanEnabled else { return }

            onPan(CGSize(
                width: location.x - lastDragLocation.x,
                height: location.y - lastDragLocation.y
            ))
            updatePointerFeedback(at: location)
        }

        override func mouseUp(with event: NSEvent) {
            let location = eventLocation(event)
            if !didPan {
                onClick(location, event.clickCount)
            }
            mouseDownLocation = nil
            lastDragLocation = nil
            shouldPanFromMouseDownLocation = false
            didPan = false
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            contextMenu(eventLocation(event))
        }

        override func magnify(with event: NSEvent) {
            let location = eventLocation(event)
            onMagnify(location, max(0.75, 1 + event.magnification))
            updatePointerFeedback(at: location)
        }

        override func scrollWheel(with event: NSEvent) {
            let location = eventLocation(event)
            let zoomModifiers: NSEvent.ModifierFlags = [.command, .option]

            if !event.modifierFlags.intersection(zoomModifiers).isEmpty {
                let scrollDelta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : -event.scrollingDeltaX
                guard scrollDelta != 0 else { return }

                onMagnify(location, pow(1.0025, scrollDelta))
                updatePointerFeedback(at: location)
                return
            }

            if isPanEnabled {
                guard let panDelta = panDelta(for: event) else { return }
                onPan(panDelta)
                updatePointerFeedback(at: location)
                return
            }

            super.scrollWheel(with: event)
        }

        private func updateHelp(at location: CGPoint) {
            toolTip = help(location)
        }

        private func updatePointerFeedback(at location: CGPoint) {
            onHover(location)
            updateHelp(at: location)
        }

        private func eventLocation(_ event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        private func didExceedDragThreshold(from start: CGPoint, to end: CGPoint) -> Bool {
            let dx = end.x - start.x
            let dy = end.y - start.y
            return ((dx * dx) + (dy * dy)) >= (Self.dragThreshold * Self.dragThreshold)
        }

        private func panDelta(for event: NSEvent) -> CGSize? {
            var delta = CGSize(
                width: event.scrollingDeltaX,
                height: event.scrollingDeltaY
            )

            guard delta != .zero else { return nil }

            if !event.isDirectionInvertedFromDevice {
                delta.width *= -1
                delta.height *= -1
            }

            if !event.hasPreciseScrollingDeltas {
                delta.width *= Self.lineScrollScale
                delta.height *= Self.lineScrollScale
            }

            return CGSize(
                width: delta.width.clampedScrollPanDelta,
                height: delta.height.clampedScrollPanDelta
            )
        }
    }
}

private extension CGFloat {
    var clampedScrollPanDelta: CGFloat {
        Swift.min(
            Swift.max(self, -SunburstInteractionOverlay.InteractionView.maximumScrollPanDelta),
            SunburstInteractionOverlay.InteractionView.maximumScrollPanDelta
        )
    }
}
