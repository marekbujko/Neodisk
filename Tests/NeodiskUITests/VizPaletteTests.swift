import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The colorblind palette and its wiring through the kind catalog.
@MainActor
@Suite struct VizPaletteTests {
    @Test func testStandardPaletteMirrorsTheDefaultColors() {
        // The `.standard` palette is just a gathered view of the values that
        // live on FileKindCatalog / AgeBucket, so it must match them exactly.
        #expect(VizPalette.standard.kindPalette == FileKindCatalog.palette)
        #expect(VizPalette.standard.categoryRGB == FileKindCatalog.categoryRGB)
        for bucket in AgeBucket.allCases {
            #expect(VizPalette.standard.ageRGB(bucket) == bucket.rgb)
        }
    }

    @Test func testColorblindPaletteCoversEveryKindSlotAndCategory() {
        // A colorblind color for every rank the standard palette colors, and
        // for every fixed category, so nothing silently falls back to grey.
        #expect(VizPalette.colorblind.kindPalette.count == VizPalette.standard.kindPalette.count)
        #expect(
            Set(VizPalette.colorblind.categoryRGB.keys) == Set(VizPalette.standard.categoryRGB.keys)
        )
        #expect(VizPalette.colorblind.ageRamp.count == AgeBucket.allCases.count)
    }

    @Test func testColorblindPaletteActuallyDiffersFromStandard() {
        #expect(VizPalette.colorblind != VizPalette.standard)
        // The age ramp is the biggest change (rainbow → viridis): every dated
        // bucket must move.
        for bucket in AgeBucket.allCases where bucket != .unknown {
            #expect(VizPalette.colorblind.ageRGB(bucket) != VizPalette.standard.ageRGB(bucket))
        }
    }

    @Test func testCatalogBakesTheSelectedPaletteIntoKindColors() {
        let png = makeTestFileNode(id: "/r/a.png", name: "a.png", size: 100)
        let root = makeTestDirectoryNode(id: "/r", name: "r", children: [png])
        let store = FileTreeStore(root: root, childrenByID: ["/r": [png]])

        let standard = FileKindCatalog.build(from: store, mode: .categories, palette: .standard)
        let colorblind = FileKindCatalog.build(from: store, mode: .categories, palette: .colorblind)

        // Images are the first (only) category here; the baked color must come
        // from whichever palette built the catalog.
        #expect(standard.rgb(for: png) == VizPalette.standard.categoryRGB["cat-image"])
        #expect(colorblind.rgb(for: png) == VizPalette.colorblind.categoryRGB["cat-image"])
        #expect(standard.rgb(for: png) != colorblind.rgb(for: png))
    }
}
