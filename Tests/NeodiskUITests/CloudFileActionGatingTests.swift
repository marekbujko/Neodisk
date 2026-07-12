import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Filesystem actions (Reveal in Finder / Open / Copy Path / double-click
/// reveal) and duplicate detection must be gated off for a cloud snapshot,
/// whose node paths are `cloudscan://` identifiers rather than on-disk files.
@MainActor
@Suite(.serialized) struct CloudFileActionGatingTests {
    @Test func testFileActionsGatedByCloudSnapshot() {
        let node = makeTestFileNode(id: "cloudscan://acct/report.pdf", name: "report.pdf")

        let cloudModel = makeDisplayingModel(kind: .cloud, node: node)
        #expect(cloudModel.snapshotSupportsFileActions == false)
        #expect(cloudModel.supportsFileActions(node) == false)

        let folderModel = makeDisplayingModel(kind: .folder, node: node)
        #expect(folderModel.snapshotSupportsFileActions == true)
        #expect(folderModel.supportsFileActions(node) == true)
    }

    @Test func testDuplicatesCannotScanCloudSnapshot() {
        let node = makeTestFileNode(id: "cloudscan://acct/report.pdf", name: "report.pdf")

        let cloudModel = makeDisplayingModel(kind: .cloud, node: node)
        #expect(cloudModel.duplicates.canScan == false)

        let folderModel = makeDisplayingModel(kind: .folder, node: node)
        #expect(folderModel.duplicates.canScan == true)
    }

    /// A view model displaying a single-file snapshot of the given target kind.
    private func makeDisplayingModel(kind: ScanTargetKind, node: FileNodeRecord) -> NeodiskViewModel {
        let target = ScanTarget(
            id: "cloudscan://acct",
            url: URL(string: "cloudscan://acct")!,
            displayName: "Account",
            kind: kind
        )
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [node])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [node]])
        let snapshot = makeTestSnapshot(target: target, root: root, store: store)

        let model = NeodiskViewModel()
        model.coordinator.replaceCurrentSnapshot(snapshot)
        return model
    }
}
