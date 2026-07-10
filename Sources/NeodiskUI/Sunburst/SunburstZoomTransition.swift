//
//  SunburstZoomTransition.swift
//  Neodisk
//
//  DaisyDisk-style drill transition for the sunburst: the clicked segment's
//  arc sweeps open to the full circle while its band morphs into the center
//  disk, its descendants shift up one ring per level, and everything outside
//  the arc collapses to zero width; zooming out plays the exact reverse on
//  the incoming parent layout. Pure polar remapping over already-styled
//  segments, so tab colors, highlights, the colorblind palette, and the
//  free-space arc all carry through unchanged.
//

import CoreGraphics
import Foundation
import SwiftUI

/// A segment's polar geometry mid-transition, in the same normalized
/// coordinates as SunburstSegment (radians clockwise from 12 o'clock, radii
/// as fractions of the chart radius).
struct SunburstZoomArc: Equatable {
    var startRadians: Double
    var endRadians: Double
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    /// Collapsed arcs (outside the focus wedge, or radially swallowed by the
    /// center) are skipped instead of stroked as hairline slivers.
    var isDrawable: Bool {
        endRadians - startRadians > 0.0004 && outerRadius - innerRadius > 0.0004
    }
}

enum SunburstZoomGeometry {
    /// Staggered per-segment timing over the linear transition progress:
    /// the outgoing shell (ancestors, siblings, anything not under the
    /// focus) collapses fast — done by this fraction — while descendants
    /// start a beat later and glide over the rest of the duration. The
    /// focus itself keeps the plain full-length curve, bridging the two.
    static let collapseFinishFraction = 0.55
    static let descendantStartFraction = 0.12
    /// The shell fades out over this much of its own schedule, so it is
    /// gone well before its collapse completes — ancestor rings never read
    /// as a circle closing on the center. (Mirrored on zoom-out: the
    /// parent shell fades in while fanning outward.)
    static let shellFadeOutFraction = 0.7
    /// The focus stays opaque while its arc sweeps open, then fades over
    /// this window of its schedule — gone before its band seals into a
    /// disk at the center (the same closing-circle read as the shell).
    static let focusFadeStartFraction = 0.55
    static let focusFadeEndFraction = 0.9

    /// Where a segment of the focus's layout sits once the chart is fully
    /// zoomed into `focus`: the focus itself becomes the center disk,
    /// descendants shift up `focus.depth + 1` rings with their angles
    /// remapped from the focus arc onto the full circle, ancestors shrink
    /// into the center, and segments outside the arc clamp to zero width.
    nonisolated static func zoomedArc(
        for segment: SunburstSegment,
        focus: SunburstSegment
    ) -> SunburstZoomArc {
        if segment.id == focus.id {
            return SunburstZoomArc(
                startRadians: 0,
                endRadians: .pi * 2,
                innerRadius: 0,
                outerRadius: SunburstLayout.centerRadius
            )
        }

        let span = max(focus.endAngle.radians - focus.startAngle.radians, 1e-9)
        func remappedRadians(_ radians: Double) -> Double {
            min(max((radians - focus.startAngle.radians) / span, 0), 1) * .pi * 2
        }

        // The full ring band width — segments draw their outer edge short of
        // it by the cosmetic ring gap, so add the gap back before re-banding.
        let ringWidth = (focus.outerRadius + SunburstLayout.ringGap) - focus.innerRadius
        let relativeDepth = CGFloat(segment.depth - focus.depth - 1)
        let innerRadius = SunburstLayout.centerRadius + (relativeDepth * ringWidth)
        let outerRadius = innerRadius + ringWidth - SunburstLayout.ringGap

        return SunburstZoomArc(
            startRadians: remappedRadians(segment.startAngle.radians),
            endRadians: remappedRadians(segment.endAngle.radians),
            innerRadius: max(0, innerRadius),
            outerRadius: max(0, outerRadius)
        )
    }

    nonisolated static func identityArc(for segment: SunburstSegment) -> SunburstZoomArc {
        SunburstZoomArc(
            startRadians: segment.startAngle.radians,
            endRadians: segment.endAngle.radians,
            innerRadius: segment.innerRadius,
            outerRadius: segment.outerRadius
        )
    }

    /// Blend between the segment's own geometry (progress 0) and its fully
    /// zoomed geometry (progress 1). Progress arrives linear; each segment
    /// eases on its own staggered timing (see `timedProgress`).
    nonisolated static func arc(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        progress rawProgress: Double
    ) -> SunburstZoomArc {
        let progress = timedProgress(for: segment, focus: focus, rawProgress: rawProgress)
        let identity = identityArc(for: segment)
        guard progress > 0 else { return identity }
        let zoomed = zoomedArc(for: segment, focus: focus)
        guard progress < 1 else { return zoomed }

        return SunburstZoomArc(
            startRadians: lerp(identity.startRadians, zoomed.startRadians, progress),
            endRadians: lerp(identity.endRadians, zoomed.endRadians, progress),
            innerRadius: CGFloat(lerp(Double(identity.innerRadius), Double(zoomed.innerRadius), progress)),
            outerRadius: CGFloat(lerp(Double(identity.outerRadius), Double(zoomed.outerRadius), progress))
        )
    }

    /// Fractional ring depth for the depth-faded fill, blended on the same
    /// staggered timing as the geometry so a ring doesn't pop a shade at
    /// the handoff to the real layout (where the same node is one depth
    /// shallower).
    nonisolated static func effectiveDepth(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        progress rawProgress: Double
    ) -> Double {
        let progress = timedProgress(for: segment, focus: focus, rawProgress: rawProgress)
        let target = Double(segment.depth - focus.depth - 1)
        return max(0, lerp(Double(segment.depth), target, progress))
    }

    /// A segment's eased progress on its class's schedule. Descendants are
    /// the segments strictly inside the focus wedge — a deeper segment
    /// under a sibling collapses with the shell, not with the reveal.
    nonisolated static func timedProgress(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        rawProgress: Double
    ) -> Double {
        let raw = min(max(rawProgress, 0), 1)
        if segment.id == focus.id {
            return easeInOut(raw)
        }
        if isDescendant(segment, of: focus) {
            return easeInOut((raw - descendantStartFraction) / (1 - descendantStartFraction))
        }

        return easeInOut(raw / collapseFinishFraction)
    }

    /// A segment's fill opacity multiplier: the collapsing shell fades out
    /// over the first `shellFadeOutFraction` of its schedule, the focus
    /// holds through its sweep and fades before sealing into a center
    /// disk, and descendants stay opaque throughout.
    nonisolated static func opacity(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        rawProgress: Double
    ) -> Double {
        if isDescendant(segment, of: focus) {
            return 1
        }

        let timed = timedProgress(for: segment, focus: focus, rawProgress: rawProgress)
        if segment.id == focus.id {
            let fadeSpan = focusFadeEndFraction - focusFadeStartFraction
            return 1 - min(max((timed - focusFadeStartFraction) / fadeSpan, 0), 1)
        }

        return 1 - min(timed / shellFadeOutFraction, 1)
    }

    private nonisolated static func isDescendant(
        _ segment: SunburstSegment,
        of focus: SunburstSegment
    ) -> Bool {
        segment.depth > focus.depth
            && segment.startAngle.radians >= focus.startAngle.radians - 1e-9
            && segment.endAngle.radians <= focus.endAngle.radians + 1e-9
    }

    nonisolated static func easeInOut(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        if clamped < 0.5 {
            return 4 * clamped * clamped * clamped
        }
        let inverted = -2 * clamped + 2
        return 1 - (inverted * inverted * inverted) / 2
    }

    private nonisolated static func lerp(_ from: Double, _ to: Double, _ t: Double) -> Double {
        from + ((to - from) * t)
    }
}

/// View-local state for one drill transition, owned by SunburstChartView.
/// All rendering derives deterministically from this plus the current frame
/// date (via SunburstZoomPresentation), so the animation needs no SwiftUI
/// animation plumbing — a TimelineView redraws it each frame.
struct SunburstZoomTransitionState {
    enum Direction {
        case zoomIn
        case zoomOut
    }

    static let geometryDuration: TimeInterval = 0.4
    static let handoffDuration: TimeInterval = 0.14
    /// Give up and fall back to the normal pending UI if the target layout
    /// has not landed by then (huge folders, slow disks).
    static let waitingForLayoutTimeout: TimeInterval = 1.5

    let id = UUID()
    let direction: Direction
    let startDate: Date
    /// Segments animated through the polar remap: the outgoing layout for
    /// zoom-in; the incoming parent layout for zoom-out (set once it lands).
    var animatedSegments: [SunburstSegment]
    /// The drilled node's segment within `animatedSegments`' layout.
    var focus: SunburstSegment?
    /// Zoom-out: the outgoing drilled-in chart, drawn as-is until the parent
    /// layout lands (its orphaned outermost rings then fade at the handoff).
    var previousSegments: [SunburstSegment]
    /// Zoom-out: the outgoing root, resolved to `focus` in the new layout.
    let previousRootID: String?
    var layoutReadyDate: Date?
    /// Zoom-in: the landed target layout the handoff reveals.
    var incomingSegments: [SunburstSegment] = []
    /// Rings deeper than this have no remapped counterpart — the remap can
    /// only carry what the outgoing/incoming layout drew. They alpha-fade
    /// at the handoff (in for zoom-in, out for zoom-out) instead of popping.
    var handoffFadeDepthThreshold = Int.max

    static func zoomIn(
        segments: [SunburstSegment],
        focus: SunburstSegment,
        startDate: Date = Date()
    ) -> SunburstZoomTransitionState {
        SunburstZoomTransitionState(
            direction: .zoomIn,
            startDate: startDate,
            animatedSegments: segments,
            focus: focus,
            previousSegments: [],
            previousRootID: nil,
            layoutReadyDate: nil
        )
    }

    static func zoomOut(
        previousSegments: [SunburstSegment],
        previousRootID: String,
        startDate: Date = Date()
    ) -> SunburstZoomTransitionState {
        SunburstZoomTransitionState(
            direction: .zoomOut,
            startDate: startDate,
            animatedSegments: [],
            focus: nil,
            previousSegments: previousSegments,
            previousRootID: previousRootID,
            layoutReadyDate: nil
        )
    }
}

/// What the transition canvas shows this frame. Exactly one scene draws at
/// a time — the phases never stack two full arc passes, so alpha-blended
/// fills can't double up (a brightness flash), and nothing paints a
/// background, so the pane behind the chart shows through untouched.
/// Phase boundaries land on pixel-identical content: the remap preserves
/// each segment's angular proportions, colors, and depth fade, so switching
/// between a settled remap and the real layout is an invisible cut. The
/// only rings that differ — deeper than `handoffFadeDepthThreshold`, which
/// the remap could not carry — alpha-fade as a single layer over the pane.
enum SunburstZoomPhase: Equatable {
    /// Segments remapped toward (zoom-in) or away from (zoom-out) the focus.
    case zooming(progress: Double)
    /// Zoom-in handoff: the landed target layout, its uncarried deep rings
    /// fading in ("new rings radiate") — everything else already matches
    /// the settled remap pixel-for-pixel.
    case revealingIncoming(alpha: Double)
    /// Zoom-out, parent layout still loading: the outgoing chart, held.
    case holdingPrevious
    /// Zoom-out handoff: the remapped parent held fully zoomed (matching
    /// the outgoing chart) while the outgoing chart's orphaned outermost
    /// rings fade away before the reverse motion starts.
    case fadingOrphans(alpha: Double)
}

/// Everything one frame of the transition needs, computed from the state
/// and the frame date.
struct SunburstZoomPresentation {
    let phase: SunburstZoomPhase
    let isFinished: Bool

    init(state: SunburstZoomTransitionState, now: Date) {
        let geometryDuration = SunburstZoomTransitionState.geometryDuration
        let handoffDuration = SunburstZoomTransitionState.handoffDuration

        switch state.direction {
        case .zoomIn:
            let elapsed = now.timeIntervalSince(state.startDate)

            // The handoff waits for both the motion to fully settle and the
            // real layout to exist; until then the remap holds the zoomed
            // frame.
            if let layoutReadyDate = state.layoutReadyDate {
                let handoffStart = max(
                    state.startDate.addingTimeInterval(geometryDuration),
                    layoutReadyDate
                )
                let handoffElapsed = now.timeIntervalSince(handoffStart)
                if handoffElapsed >= 0 {
                    phase = .revealingIncoming(
                        alpha: min(handoffElapsed / handoffDuration, 1)
                    )
                    isFinished = handoffElapsed >= handoffDuration
                    return
                }
            }

            phase = .zooming(progress: min(max(elapsed / geometryDuration, 0), 1))
            isFinished = state.layoutReadyDate == nil
                && elapsed > geometryDuration
                    + SunburstZoomTransitionState.waitingForLayoutTimeout

        case .zoomOut:
            guard let layoutReadyDate = state.layoutReadyDate, state.focus != nil else {
                phase = .holdingPrevious
                isFinished = now.timeIntervalSince(state.startDate)
                    > SunburstZoomTransitionState.waitingForLayoutTimeout
                return
            }

            let elapsed = now.timeIntervalSince(layoutReadyDate)
            if elapsed < handoffDuration {
                phase = .fadingOrphans(alpha: 1 - (elapsed / handoffDuration))
                isFinished = false
            } else {
                let reverseElapsed = elapsed - handoffDuration
                phase = .zooming(
                    progress: 1 - min(reverseElapsed / geometryDuration, 1)
                )
                // Ends pixel-identical to the real layout below — the
                // teardown when this flips is an invisible cut.
                isFinished = reverseElapsed >= geometryDuration
            }
        }
    }
}

/// The transition frame: one scene per phase, no background, no stacked
/// layers. Segments draw in layout order — ancestors precede descendants
/// in the segment array, so the expanding focus disk covers its collapsing
/// ancestors.
struct SunburstZoomTransitionCanvas: View {
    let state: SunburstZoomTransitionState
    let presentation: SunburstZoomPresentation

    var body: some View {
        Canvas { context, size in
            switch presentation.phase {
            case .zooming(let progress):
                guard let focus = state.focus else { return }
                drawRemapped(
                    state.animatedSegments,
                    focus: focus,
                    progress: progress,
                    in: &context,
                    size: size
                )

            case .revealingIncoming(let alpha):
                drawIdentity(
                    state.incomingSegments,
                    alphaForDeepRings: alpha,
                    deeperThan: state.handoffFadeDepthThreshold,
                    in: &context,
                    size: size
                )

            case .holdingPrevious:
                drawIdentity(
                    state.previousSegments,
                    alphaForDeepRings: 1,
                    deeperThan: Int.max,
                    in: &context,
                    size: size
                )

            case .fadingOrphans(let alpha):
                if let focus = state.focus {
                    drawRemapped(
                        state.animatedSegments,
                        focus: focus,
                        progress: 1,
                        in: &context,
                        size: size
                    )
                }
                // The orphaned rings sit in a band the remap leaves empty,
                // so this second pass never overlaps the first.
                drawIdentity(
                    state.previousSegments,
                    alphaForDeepRings: alpha,
                    deeperThan: state.handoffFadeDepthThreshold,
                    onlyDeepRings: true,
                    in: &context,
                    size: size
                )
            }
        }
    }

    private func drawRemapped(
        _ segments: [SunburstSegment],
        focus: SunburstSegment,
        progress: Double,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        for segment in segments {
            let segmentOpacity = SunburstZoomGeometry.opacity(
                for: segment,
                focus: focus,
                rawProgress: progress
            )
            guard segmentOpacity > 0.001 else { continue }

            context.opacity = segmentOpacity
            draw(
                segment,
                arc: SunburstZoomGeometry.arc(for: segment, focus: focus, progress: progress),
                effectiveDepth: SunburstZoomGeometry.effectiveDepth(
                    for: segment,
                    focus: focus,
                    progress: progress
                ),
                in: &context,
                size: size
            )
        }
    }

    private func drawIdentity(
        _ segments: [SunburstSegment],
        alphaForDeepRings: Double,
        deeperThan threshold: Int,
        onlyDeepRings: Bool = false,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        for segment in segments {
            let isDeepRing = segment.depth > threshold
            if onlyDeepRings, !isDeepRing { continue }

            let segmentOpacity = isDeepRing ? alphaForDeepRings : 1
            guard segmentOpacity > 0.001 else { continue }

            context.opacity = segmentOpacity
            draw(
                segment,
                arc: SunburstZoomGeometry.identityArc(for: segment),
                effectiveDepth: Double(segment.depth),
                in: &context,
                size: size
            )
        }
    }

    private func draw(
        _ segment: SunburstSegment,
        arc: SunburstZoomArc,
        effectiveDepth: Double,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard arc.isDrawable else { return }

        let path = SunburstRenderer.path(for: arc, in: size)
        let style = SunburstChartStyler.baseStyle(for: segment, effectiveDepth: effectiveDepth)
        context.fill(path, with: .color(style.fillColor))
        context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
    }
}
