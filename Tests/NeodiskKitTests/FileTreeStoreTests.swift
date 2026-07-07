import Testing
import Foundation
@testable import NeodiskKit

@Suite struct FileTreeStoreTests {
    @Test func testPathAndAncestorLookup() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [leaf],
        ])

        #expect(store.path(to: leaf.id).map(\.name) == ["root", "folder", "file.txt"])
        #expect(store.isAncestor(root.id, of: leaf.id))
        #expect(store.isAncestor(folder.id, of: leaf.id))
        #expect(!(store.isAncestor(leaf.id, of: folder.id)))
        #expect(store.parent(of: leaf.id)?.id == folder.id)
    }

    @Test func testTopLevelNodeIDsDropsDescendantsOfQueuedParents() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [leaf],
        ])

        #expect(store.topLevelNodeIDs(from: [leaf.id, folder.id, sibling.id, folder.id]) == [folder.id, sibling.id])
        #expect(store.isNodeOrDescendant(leaf.id, of: [folder.id]))
        #expect(!(store.isNodeOrDescendant(sibling.id, of: [folder.id])))
    }

    @Test func testRemovingSubtreesRemovesQueuedParentsAndRepairsTotals() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [leaf],
        ])

        let updatedStore = store.removingSubtrees(rootedAt: [leaf.id, folder.id])

        #expect(updatedStore.node(id: folder.id) == nil)
        #expect(updatedStore.node(id: leaf.id) == nil)
        #expect(updatedStore.children(of: root.id).map(\.id) == [sibling.id])
        #expect(updatedStore.root.allocatedSize == sibling.allocatedSize)
        #expect(updatedStore.root.descendantFileCount == 1)
        #expect(updatedStore.aggregateStats.fileCount == 1)
        #expect(updatedStore.aggregateStats.directoryCount == 1)
    }

    @Test func testRemovingSubtreesRootReturnsEmptyRootStore() {
        let child = makeFileNode(id: "/root/child.txt", name: "child.txt", size: 12)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])

        let updatedStore = store.removingSubtrees(rootedAt: [root.id])

        #expect(updatedStore.root.id == root.id)
        #expect(updatedStore.root.allocatedSize == 0)
        #expect(updatedStore.root.descendantFileCount == 0)
        #expect(updatedStore.children(of: root.id).isEmpty)
        #expect(updatedStore.aggregateStats.fileCount == 0)
    }

    @Test func testIndexedNodeIDsPreserveTraversalOrderAndCanExcludeRoot() {
        let first = makeFileNode(id: "/root/a.txt", name: "a.txt", size: 12)
        let nested = makeFileNode(id: "/root/folder/b.txt", name: "b.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [first, folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [first, folder],
            folder.id: [nested],
        ])

        #expect(store.indexedNodeIDs() == ["/root", "/root/a.txt", "/root/folder", "/root/folder/b.txt"])
        #expect(store.indexedNodeIDs(excludingRoot: true) == ["/root/a.txt", "/root/folder", "/root/folder/b.txt"])

        var iteratedIDs: [String] = []
        store.forEachIndexedNodeID(excludingRoot: true) { id in
            iteratedIDs.append(id)
        }
        #expect(iteratedIDs == ["/root/a.txt", "/root/folder", "/root/folder/b.txt"])
    }

    @Test func testEmptyStoreFallsBackToRootPath() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [])
        let store = FileTreeStore(root: root)

        #expect(store.path(to: nil).map(\.id) == [root.id])
        #expect(store.children(of: nil).count == 0)
    }

    @Test func testUnknownNodeFallsBackToRootPath() {
        let child = makeFileNode(id: "/root/child.txt", name: "child.txt", size: 12)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])

        #expect(store.path(to: "/root/missing").map(\.id) == [root.id])
        #expect(store.node(id: "/root/missing") == nil)
        #expect(store.parent(of: "/root/missing") == nil)
    }

    @Test func testChildrenPrefixPreservesOrderAndLimit() {
        let children = (0..<6).map { index in
            makeFileNode(id: "/root/item-\(index).txt", name: "item-\(index).txt", size: Int64(10 - index))
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])

        #expect(store.childrenPrefix(of: root.id, maxCount: 3).map(\.id) == children.prefix(3).map(\.id))
        #expect(store.childrenPrefix(of: root.id, maxCount: 99).count == children.count)
        #expect(store.childrenPrefix(of: root.id, maxCount: 0).isEmpty)
    }

    @Test func testChildrenByIDInitializerDropsLaterDuplicateNodeIDs() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, dropped])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, dropped],
        ])

        #expect(store.children(of: root.id).map(\.name) == ["kept.txt"])
        #expect(store.node(id: kept.id)?.name == "kept.txt")
        #expect(store.parent(of: kept.id)?.id == root.id)
        #expect(store.indexedNodeIDs() == [root.id, kept.id])
        #expect(store.root.allocatedSize == kept.allocatedSize)
        #expect(store.root.logicalSize == kept.logicalSize)
        #expect(store.root.descendantFileCount == 1)
        #expect(store.aggregateStats.totalAllocatedSize == kept.allocatedSize)
        #expect(store.aggregateStats.fileCount == 1)
    }

    @Test func testChildrenByIDInitializerRepairsNestedDuplicateTotals() {
        let shared = makeFileNode(id: "/root/shared.txt", name: "shared.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [shared])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [shared, folder])

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [shared, folder],
            folder.id: [shared],
        ])

        #expect(Set(store.children(of: root.id).map(\.id)) == Set([shared.id, folder.id]))
        #expect(store.children(of: folder.id).isEmpty)
        #expect(store.node(id: folder.id)?.allocatedSize == 0)
        #expect(store.node(id: folder.id)?.logicalSize == 0)
        #expect(store.node(id: folder.id)?.descendantFileCount == 0)
        #expect(store.root.allocatedSize == shared.allocatedSize)
        #expect(store.root.logicalSize == shared.logicalSize)
        #expect(store.root.descendantFileCount == 1)
        #expect(store.aggregateStats.totalAllocatedSize == shared.allocatedSize)
        #expect(store.aggregateStats.fileCount == 1)
    }

    @Test func testChildrenByIDInitializerRepairsAccessibilityAfterDroppingDuplicates() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50, isAccessible: false)
        let root = makeDirectoryNode(
            id: "/root",
            name: "root",
            children: [kept, dropped],
            isAccessible: false,
            isSelfAccessible: true
        )

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, dropped],
        ])

        #expect(store.root.isAccessible)
        #expect(store.aggregateStats.accessibleItemCount == 2)
        #expect(store.aggregateStats.inaccessibleItemCount == 0)
    }

    @Test func testChildrenByIDInitializerPreservesSelfInaccessibleDirectoryAfterDroppingDuplicates() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50, isAccessible: false)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, dropped], isAccessible: false)

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, dropped],
        ])

        #expect(!(store.root.isAccessible))
        #expect(store.aggregateStats.accessibleItemCount == 1)
        #expect(store.aggregateStats.inaccessibleItemCount == 1)
    }

    @Test func testChildrenByIDInitializerOrdersByKeptChildrenWhenDuplicateIsLarger() {
        let kept = makeFileNode(id: "/root/a.txt", name: "a.txt", size: 1)
        let sibling = makeFileNode(id: "/root/b.txt", name: "b.txt", size: 50)
        let dropped = makeFileNode(id: kept.id, name: "dropped-a.txt", size: 100)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, sibling, dropped])

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, sibling, dropped],
        ])

        #expect(store.children(of: root.id).map(\.id) == [sibling.id, kept.id])
        #expect(store.root.allocatedSize == sibling.allocatedSize + kept.allocatedSize)
    }

    @Test func testFlatInitializerDropsDuplicateChildReferences() {
        let shared = makeFileNode(id: "/root/shared.txt", name: "shared.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [shared])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [shared, folder])
        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: [
                root.id: root,
                shared.id: shared,
                folder.id: folder,
            ],
            childIDsByID: [
                root.id: [shared.id, folder.id, shared.id],
                folder.id: [shared.id],
            ],
            parentIDByID: [
                shared.id: folder.id,
                folder.id: root.id,
            ]
        )

        #expect(store.children(of: root.id).map(\.id) == [shared.id, folder.id])
        #expect(store.children(of: folder.id).isEmpty)
        #expect(store.parent(of: shared.id)?.id == root.id)
        #expect(store.indexedNodeIDs() == [root.id, shared.id, folder.id])
        #expect(store.node(id: folder.id)?.allocatedSize == 0)
        #expect(store.node(id: folder.id)?.logicalSize == 0)
        #expect(store.node(id: folder.id)?.descendantFileCount == 0)
        #expect(store.root.allocatedSize == shared.allocatedSize)
        #expect(store.root.logicalSize == shared.logicalSize)
        #expect(store.root.descendantFileCount == 1)
        #expect(store.aggregateStats.totalAllocatedSize == shared.allocatedSize)
        #expect(store.aggregateStats.fileCount == 1)
    }

    @Test func testFlatInitializerPreservesPrecomputedStatsForEmptyChildArrays() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [])
        let precomputedStats = ScanAggregateStats(
            totalAllocatedSize: 99,
            totalLogicalSize: 101,
            fileCount: 42,
            directoryCount: 7,
            accessibleItemCount: 6,
            inaccessibleItemCount: 1
        )

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [root.id: []],
            parentIDByID: [:],
            aggregateStats: precomputedStats
        )

        #expect(store.aggregateStats.totalAllocatedSize == precomputedStats.totalAllocatedSize)
        #expect(store.aggregateStats.totalLogicalSize == precomputedStats.totalLogicalSize)
        #expect(store.aggregateStats.fileCount == precomputedStats.fileCount)
        #expect(store.aggregateStats.directoryCount == precomputedStats.directoryCount)
        #expect(store.aggregateStats.accessibleItemCount == precomputedStats.accessibleItemCount)
        #expect(store.aggregateStats.inaccessibleItemCount == precomputedStats.inaccessibleItemCount)
    }

    @Test func testFlatInitializerPreservesInaccessibleEmptyMaterializedDirectory() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [], isAccessible: false)

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [root.id: []],
            parentIDByID: [:]
        )

        #expect(!(store.root.isAccessible))
        #expect(store.aggregateStats.accessibleItemCount == 0)
        #expect(store.aggregateStats.inaccessibleItemCount == 1)
    }

    @Test func testReplacingSubtreeRejectsReplacementIDsOutsideOldSubtree() throws {
        let targetChild = makeFileNode(id: "/root/target/old.txt", name: "old.txt", size: 4)
        let target = makeDirectoryNode(id: "/root/target", name: "target", children: [targetChild])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 8)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [target, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [target, sibling],
            target.id: [targetChild],
        ])
        let collidingReplacementChild = makeFileNode(id: sibling.id, name: "collision.txt", size: 99)
        let replacementRoot = makeDirectoryNode(
            id: target.id,
            name: "target",
            children: [collidingReplacementChild]
        )
        let replacementStore = FileTreeStore(root: replacementRoot, childrenByID: [
            replacementRoot.id: [collidingReplacementChild],
        ])

        let error: any Error = try #require(throws: (any Error).self) {
            try store.replacingSubtree(
                id: target.id,
                with: replacementStore,
                cancellationCheck: {}
            )
        }
        #expect(error.localizedDescription.contains("reuses an existing node ID"))
        #expect(error.localizedDescription.contains(sibling.id))
        #expect(store.replacingSubtree(id: target.id, with: replacementStore) == nil)
        #expect(store.node(id: sibling.id)?.name == sibling.name)
    }

    @Test func testReplacingRootCanChangeRootID() throws {
        let oldChild = makeFileNode(id: "/root/old.txt", name: "old.txt", size: 4)
        let oldRoot = makeDirectoryNode(id: "/root", name: "root", children: [oldChild])
        let store = FileTreeStore(root: oldRoot, childrenByID: [
            oldRoot.id: [oldChild],
        ])
        let newChild = makeFileNode(id: "/replacement/new.txt", name: "new.txt", size: 12)
        let newRoot = makeDirectoryNode(id: "/replacement", name: "replacement", children: [newChild])
        let replacementStore = FileTreeStore(root: newRoot, childrenByID: [
            newRoot.id: [newChild],
        ])

        let updated = try #require(
            try store.replacingSubtree(
                id: oldRoot.id,
                with: replacementStore,
                cancellationCheck: {}
            )
        )

        #expect(updated.root.id == newRoot.id)
        #expect(updated.children(of: newRoot.id).map(\.id) == [newChild.id])
        #expect(updated.node(id: oldRoot.id) == nil)
        #expect(updated.node(id: oldChild.id) == nil)
    }

    @Test func testDeepTreeIndexingAndAggregateStatsAvoidRecursiveTraversal() {
        let depth = 5_000
        let leafID = "/root/file.txt"
        let leaf = makeFileNode(id: leafID, name: "file.txt", size: 12)
        var nodesByID = [leaf.id: leaf]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var childID = leaf.id

        for level in stride(from: depth, through: 1, by: -1) {
            let nodeID = "/root/level-\(level)"
            let directory = makeDirectoryNode(
                id: nodeID,
                name: "level-\(level)",
                children: [nodesByID[childID]!]
            )
            nodesByID[nodeID] = directory
            childIDsByID[nodeID] = [childID]
            parentIDByID[childID] = nodeID
            childID = nodeID
        }

        let root = makeDirectoryNode(id: "/root", name: "root", children: [nodesByID[childID]!])
        nodesByID[root.id] = root
        childIDsByID[root.id] = [childID]
        parentIDByID[childID] = root.id

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
        )

        #expect(store.path(to: leafID).count == depth + 2)
        #expect(store.aggregateStats.directoryCount == depth + 1)
        #expect(store.aggregateStats.fileCount == 1)
    }
}

private func makeFileNode(
    id: String,
    name: String,
    size: Int64,
    isAccessible: Bool = true
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: isAccessible,
        isSelfAccessible: isAccessible,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private func makeDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord],
    isAccessible: Bool = true,
    isSelfAccessible: Bool? = nil
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
        logicalSize: children.reduce(0) { $0 + $1.logicalSize },
        descendantFileCount: children.reduce(0) { $0 + ($1.isDirectory ? $1.descendantFileCount : 1) },
        lastModified: nil,
        isPackage: false,
        isAccessible: isAccessible,
        isSelfAccessible: isSelfAccessible ?? isAccessible,
        isSynthetic: false,
        isAutoSummarized: false
    )
}
