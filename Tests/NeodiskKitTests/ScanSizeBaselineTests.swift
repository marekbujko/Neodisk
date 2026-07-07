import Foundation
import Testing
@testable import NeodiskKit

@Suite struct ScanSizeBaselineTests {
    @Test func testBaselineReportsPreviousSizesAndDeltas() throws {
        let oldFile = makeTestFileNode(id: "/base/report.pdf", name: "report.pdf", size: 100)
        let root = makeTestDirectoryNode(id: "/base", name: "base", children: [oldFile])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldFile]])
        let snapshot = makeTestSnapshot(target: makeTestTarget("/base"), root: root, store: store)

        let baseline = ScanSizeBaseline(snapshot: snapshot)

        #expect(baseline.targetID == "/base")
        #expect(baseline.allocatedSize(forNodeID: "/base/report.pdf") == 100)
        #expect(baseline.allocatedSize(forNodeID: "/base") == 100)
        #expect(baseline.allocatedSize(forNodeID: "/base/new.bin") == nil)

        let grown = makeTestFileNode(id: "/base/report.pdf", name: "report.pdf", size: 160)
        #expect(baseline.sizeDelta(for: grown) == 60)
        let brandNew = makeTestFileNode(id: "/base/new.bin", name: "new.bin", size: 42)
        #expect(baseline.sizeDelta(for: brandNew) == 42)
    }
}
