import Foundation
import Testing
@testable import NeodiskKit

@Suite struct TreeStorageTests {
    ///     /r
    ///     ├── big/            (30)
    ///     │   ├── x.bin  (20)
    ///     │   └── y.bin  (10)
    ///     └── small.bin  (5)
    private func makeStore() -> FileTreeStore {
        let x = makeTestFileNode(id: "/r/big/x.bin", name: "x.bin", size: 20)
        let y = makeTestFileNode(id: "/r/big/y.bin", name: "y.bin", size: 10)
        let big = makeTestDirectoryNode(id: "/r/big", name: "big", children: [x, y])
        let small = makeTestFileNode(id: "/r/small.bin", name: "small.bin", size: 5)
        let root = makeTestDirectoryNode(id: "/r", name: "r", children: [big, small])
        return FileTreeStore(root: root, childrenByID: [
            root.id: [big, small],
            big.id: [x, y],
        ])
    }

    @Test func nodesArePreorderWithParentBeforeChildren() {
        let storage = makeStore().storage

        #expect(storage.nodes.map(\.id) == ["/r", "/r/big", "/r/big/x.bin", "/r/big/y.bin", "/r/small.bin"])
        #expect(storage.parentIndices == [-1, 0, 1, 1, 0])
        for (index, parent) in storage.parentIndices.enumerated() where parent >= 0 {
            #expect(Int(parent) < index)
        }
    }

    @Test func childLayoutMatchesDisplayOrder() {
        let storage = makeStore().storage

        let rootChildren = storage.childIndices(of: 0).map { storage.nodes[Int($0)].id }
        #expect(rootChildren == ["/r/big", "/r/small.bin"])
        let bigIndex = storage.index(of: "/r/big")!
        let bigChildren = storage.childIndices(of: bigIndex).map { storage.nodes[Int($0)].id }
        #expect(bigChildren == ["/r/big/x.bin", "/r/big/y.bin"])
        #expect(storage.childCount(of: storage.index(of: "/r/small.bin")!) == 0)
    }

    @Test func indexLookupCoversEveryNode() {
        let storage = makeStore().storage

        for (index, node) in storage.nodes.enumerated() {
            #expect(storage.index(of: node.id) == Int32(index))
        }
        #expect(storage.index(of: "/nope") == nil)
    }

    @Test func insertingRootChildKeepsTopologyAndOrder() throws {
        let store = makeStore()
        let synthetic = FileNodeRecord(
            id: "/r#system-unattributed",
            url: URL(filePath: "/r", directoryHint: .isDirectory),
            name: "System & Unattributed",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 100,
            logicalSize: 100,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
        let oldRoot = store.root
        let sortedChildren = FileTreeStore.sortedChildren(store.children(of: oldRoot.id) + [synthetic])
        let updatedRoot = FileNodeRecord.directory(
            id: oldRoot.id,
            url: oldRoot.url,
            name: oldRoot.name,
            children: sortedChildren,
            lastModified: oldRoot.lastModified,
            isPackage: oldRoot.isPackage,
            isAccessible: oldRoot.isSelfAccessible,
            childrenAreSorted: true
        )

        let updated = FileTreeStore(
            trustedStorage: store.storage.insertingRootChild(
                synthetic,
                updatedRoot: updatedRoot,
                rootChildOrder: sortedChildren.map(\.id)
            ),
            rootID: store.rootID
        )

        #expect(updated.nodeCount == store.nodeCount + 1)
        #expect(updated.root.allocatedSize == 135)
        // The 100-byte synthetic node sorts ahead of big/ (30) and small.bin (5).
        #expect(updated.children(of: updated.rootID).map(\.id) ==
            ["/r#system-unattributed", "/r/big", "/r/small.bin"])
        #expect(updated.parent(of: synthetic.id)?.id == updated.rootID)
        // Existing subtrees are untouched.
        #expect(updated.children(of: "/r/big").map(\.name) == ["x.bin", "y.bin"])
    }
}
