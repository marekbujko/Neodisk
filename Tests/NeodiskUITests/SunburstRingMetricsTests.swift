//
//  SunburstRingMetricsTests.swift
//  Neodisk
//
//  The tapered ring radii: the single source of truth for how deep the
//  sunburst's rings sit. DaisyDisk-style — deeper rings are thinner bands,
//  floored so they stay clickable, normalized to fill the same outer radius
//  no matter the ring count.
//

import SunburstCore
import Testing

@Suite struct SunburstRingMetricsTests {
    private let available = SunburstRingMetrics.outerRadius - SunburstLayout.centerRadius

    @Test func ringsFillExactlyFromCenterToOuterRadius() {
        for depthLimit in 1...12 {
            let metrics = SunburstRingMetrics(depthLimit: depthLimit)
            #expect(abs(metrics.innerRadius(depth: 0) - SunburstLayout.centerRadius) < 1e-12)

            let total = (0..<depthLimit).reduce(0.0) { $0 + metrics.thickness(depth: $1) }
            #expect(abs(total - available) < 1e-9)

            // The outermost band's edge lands exactly on the outer radius; the
            // drawn arc sits one ring gap short of it.
            let last = depthLimit - 1
            #expect(abs((metrics.drawnOuterRadius(depth: last) + SunburstLayout.ringGap) - SunburstRingMetrics.outerRadius) < 1e-9)
        }
    }

    @Test func thicknessIsMonotonicallyNonIncreasing() {
        let metrics = SunburstRingMetrics(depthLimit: 6)
        for depth in 1..<6 {
            // Each ring is no thicker than the one inside it — the taper only
            // ever thins outward.
            #expect(metrics.thickness(depth: depth) <= metrics.thickness(depth: depth - 1) + 1e-12)
        }
    }

    @Test func innerRingsKeepFullEqualThickness() {
        let metrics = SunburstRingMetrics(depthLimit: 6)
        // The first `fullThicknessRingCount` rings share one full thickness;
        // the taper only starts beyond them.
        #expect(abs(metrics.thickness(depth: 0) - metrics.thickness(depth: 1)) < 1e-12)
        #expect(metrics.thickness(depth: 2) < metrics.thickness(depth: 1))
    }

    @Test func outerRingsAreVisiblyThinnerThanInner() {
        let metrics = SunburstRingMetrics(depthLimit: 6)
        // The whole point: the deepest ring reads as a much thinner band than
        // the inner rings (roughly the compounded taper ratio).
        #expect(metrics.thickness(depth: 5) < metrics.thickness(depth: 0) * 0.5)
    }

    @Test func floorKeepsDeepRingsClickable() {
        // Enough rings that the geometric taper would starve the outer ones,
        // but few enough that the floor still fits: every ring stays at least
        // the floor thick, and the total never overruns.
        let metrics = SunburstRingMetrics(depthLimit: 20)
        var total = 0.0
        for depth in 0..<20 {
            let thickness = metrics.thickness(depth: depth)
            #expect(thickness >= SunburstRingMetrics.minThicknessFraction - 1e-9)
            total += thickness
        }
        #expect(abs(total - available) < 1e-9)
    }

    @Test func infeasibleFloorFallsBackToEqualSplitThatStillFits() {
        // So many rings that even an all-floor stack would overrun the span:
        // the floor is abandoned for an equal split, but the total still fills
        // exactly (correctness of the total wins over the clickability floor).
        let depthLimit = 40
        let metrics = SunburstRingMetrics(depthLimit: depthLimit)
        #expect(Double(depthLimit) * SunburstRingMetrics.minThicknessFraction > available)

        let expected = available / Double(depthLimit)
        var total = 0.0
        for depth in 0..<depthLimit {
            #expect(abs(metrics.thickness(depth: depth) - expected) < 1e-12)
            total += metrics.thickness(depth: depth)
        }
        #expect(abs(total - available) < 1e-9)
    }

    @Test func bandsAreContiguousAcrossTheRingGap() {
        let metrics = SunburstRingMetrics(depthLimit: 6)
        for depth in 0..<5 {
            // The drawn arc ends one ring gap short of the next ring's inner
            // edge — no overlap, and the gap is exactly the cosmetic seam.
            let drawnOuter = metrics.drawnOuterRadius(depth: depth)
            let nextInner = metrics.innerRadius(depth: depth + 1)
            #expect(abs((drawnOuter + SunburstLayout.ringGap) - nextInner) < 1e-12)
        }
    }

    @Test func boundaryRadiusExtrapolatesBelowCenterForCollapsingShell() {
        // The zoom remap asks for negative ring indices (an ancestor shell
        // collapsing through the center). They extrapolate monotonically past
        // the center hole so the morph stays continuous.
        let metrics = SunburstRingMetrics(depthLimit: 6)
        #expect(metrics.boundaryRadius(ringIndex: 0) == SunburstLayout.centerRadius)
        #expect(metrics.boundaryRadius(ringIndex: -1) < SunburstLayout.centerRadius)
        #expect(metrics.boundaryRadius(ringIndex: -2) < metrics.boundaryRadius(ringIndex: -1))
    }
}
