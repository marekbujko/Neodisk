//
//  SunburstViewportTransformTests.swift
//  Neodisk
//
//  Ported from Radix's viewport transform suite.
//

import CoreGraphics
import Testing
@testable import NeodiskUI

@Suite struct SunburstViewportTransformTests {
    @Test func zoomExpandsChartAroundBaseCenter() {
        let baseFrame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let transform = SunburstViewportTransform().zoomed(
            by: 2,
            anchor: nil,
            in: baseFrame
        )

        #expect(transform.scale == 2)
        #expect(transform.offset == .zero)
        #expect(transform.frame(for: baseFrame) == CGRect(x: -90, y: -30, width: 400, height: 200))
    }

    @Test func zoomAroundAnchorKeepsAnchoredPointStable() throws {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let anchor = CGPoint(x: 150, y: 100)
        let transform = SunburstViewportTransform().zoomed(
            by: 2,
            anchor: anchor,
            in: baseFrame
        )

        let localChartPoint = try #require(transform.localChartPoint(for: anchor, in: baseFrame))

        #expect(transform.offset == CGSize(width: -50, height: 0))
        #expect(localChartPoint.point == CGPoint(x: 300, y: 200))
        #expect(localChartPoint.size == CGSize(width: 400, height: 400))
    }

    @Test func panOffsetIsConstrainedToKeepBaseFrameCovered() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = SunburstViewportTransform(scale: 2).panned(
            by: CGSize(width: 500, height: -500),
            in: baseFrame
        )

        #expect(transform.offset == CGSize(width: 100, height: -50))
        #expect(transform.frame(for: baseFrame).contains(baseFrame))
    }

    @Test func constrainedShrinksOffsetForSmallerFrame() {
        let smallerFrame = CGRect(x: 0, y: 0, width: 120, height: 80)
        let transform = SunburstViewportTransform(
            scale: 2,
            offset: CGSize(width: 100, height: -100)
        ).constrained(to: smallerFrame)

        #expect(transform.offset == CGSize(width: 60, height: -40))
        #expect(transform.frame(for: smallerFrame).contains(smallerFrame))
    }

    @Test func zoomOutToMinimumResetsOffset() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = SunburstViewportTransform(
            scale: 2,
            offset: CGSize(width: 40, height: -20)
        ).zoomed(
            by: 0.1,
            anchor: CGPoint(x: 50, y: 25),
            in: baseFrame
        )

        #expect(transform == .identity)
    }

    @Test func zoomRespectsCustomMaximumScale() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = SunburstViewportTransform().zoomed(
            by: 4,
            anchor: nil,
            in: baseFrame,
            maximumScale: 2
        )

        #expect(transform.scale == 2)
    }
}
