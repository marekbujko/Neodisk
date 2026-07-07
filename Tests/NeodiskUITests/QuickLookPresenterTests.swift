import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The panel itself needs a window server, so these cover the guard that
/// decides whether a node may be previewed at all.
@Suite struct QuickLookPresenterTests {
    @Test func existingFileIsPreviewable() {
        let node = makeTestFileNode(id: "/tmp/report.pdf", name: "report.pdf")
        #expect(QuickLookPresenter.canPreview(node, fileExists: { $0 == "/tmp/report.pdf" }))
    }

    @Test func missingFileIsNotPreviewable() {
        let node = makeTestFileNode(id: "/tmp/deleted-since-scan.txt", name: "deleted-since-scan.txt")
        #expect(!QuickLookPresenter.canPreview(node, fileExists: { _ in false }))
    }

    @Test func existingDirectoryIsPreviewable() {
        let node = makeTestDirectoryNode(id: "/tmp/folder", name: "folder", children: [])
        #expect(QuickLookPresenter.canPreview(node, fileExists: { _ in true }))
    }

    @Test func syntheticNodeIsNeverPreviewableEvenIfPathExists() {
        let node = FileNodeRecord(
            id: "synthetic:system-data",
            path: "/",
            name: "System Data",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 1,
            logicalSize: 1,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
        #expect(!QuickLookPresenter.canPreview(node, fileExists: { _ in true }))
    }

    @Test func defaultExistenceCheckUsesRealFilesystem() {
        let missing = makeTestFileNode(
            id: "/tmp/neodisk-definitely-missing-\(UUID().uuidString)",
            name: "missing"
        )
        #expect(!QuickLookPresenter.canPreview(missing))

        let temporaryDirectory = makeTestDirectoryNode(
            id: NSTemporaryDirectory(),
            name: "tmp",
            children: []
        )
        #expect(QuickLookPresenter.canPreview(temporaryDirectory))
    }
}
