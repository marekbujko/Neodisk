import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The context-menu subtree action on the view model: "Expand Contents"
/// splices a fresh scan of an auto-summarized folder into the displayed
/// tree and persists the spliced snapshot back to the cache.
@MainActor
@Suite(.serialized) struct SubtreeRefreshTests {
    @Test func testExpandSkipsPlainDirectoriesWithoutScanning() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel()
        let fixture = makeSubtreeFixture(rootPath: "/subtree/skips")
        model.coordinator.replaceCurrentSnapshot(fixture.snapshot)

        // Neither a plain directory nor a file is auto-summarized, so
        // expansion never starts a scan.
        model.expandSummarizedNode(fixture.directory)
        model.expandSummarizedNode(fixture.file)

        #expect(environment.scanService.scanCount == 0)
        #expect(model.coordinator.expandingNodeID == nil)
    }

    @Test func testExpandSummarizedNodeSplicesAndRevealsContents() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel()
        let fixture = makeSummarizedFixture(rootPath: "/subtree/summarized")
        model.coordinator.replaceCurrentSnapshot(fixture.snapshot)

        #expect(model.canRefreshSubtree)
        model.expandSummarizedNode(fixture.summarized)

        // The expansion starts in a task; wait for the scan to register.
        try await waitUntilAsync("expansion scan started") {
            environment.scanService.scanCount == 1
        }
        #expect(model.coordinator.expandingNodeID == fixture.summarized.id)
        #expect(!model.canRefreshSubtree)
        #expect(environment.scanService.scanCount == 1)
        let request = try #require(environment.scanService.requests.first)
        #expect(request.target == ScanTarget(url: fixture.summarized.url))
        // Re-summarizing the folder the user asked to expand would make the
        // action a no-op.
        #expect(request.options.autoSummarizeDirectories == false)

        // A second request while the first is in flight is ignored.
        model.expandSummarizedNode(fixture.summarized)
        #expect(environment.scanService.scanCount == 1)

        let refreshed = makeRefreshedSubtreeSnapshot(directoryID: fixture.summarized.id)
        environment.scanService.yield(.finished(refreshed), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)

        try await waitUntilAsync("summarized node expanded") {
            model.store?.node(id: fixture.summarized.id)?.isAutoSummarized == false
        }
        #expect(model.store?.children(of: fixture.summarized.id).map(\.name) == ["new1.bin", "new2.bin"])
        // The replacement root is revealed and opened in the outline.
        #expect(model.expandedNodeIDs.contains(fixture.summarized.id))
        #expect(model.expandedNodeIDs.contains(fixture.snapshot.root.id))
        #expect(model.coordinator.expandingNodeID == nil)
        #expect(model.canRefreshSubtree)
        #expect(model.store?.root.id == fixture.snapshot.root.id)
        #expect(model.actionErrorMessage == nil)
    }

    @Test func testFailedSubtreeRefreshSetsActionErrorMessage() async throws {
        struct StubScanError: Error {}
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel()
        let fixture = makeSummarizedFixture(rootPath: "/subtree/failing")
        model.coordinator.replaceCurrentSnapshot(fixture.snapshot)

        model.expandSummarizedNode(fixture.summarized)
        try await waitUntilAsync("expansion scan started") {
            environment.scanService.scanCount == 1
        }
        environment.scanService.finish(scanIndex: 0, throwing: StubScanError())

        try await waitUntilAsync("failure surfaced") {
            model.actionErrorMessage != nil
        }
        #expect(model.actionErrorMessage?.contains(fixture.summarized.name) == true)
        #expect(model.coordinator.expandingNodeID == nil)
        // The displayed tree is untouched.
        #expect(model.store?.node(id: fixture.summarized.id)?.isAutoSummarized == true)
    }

    @Test func testSplicedSnapshotIsPersistedToCache() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/subtree/persisted")
        environment.pinnedFolderStore.add(target)
        let model = environment.makeModel()

        // Full scan first: it persists and records the honest full-scan
        // date/duration in the cache index.
        model.startScan(target)
        let fixture = makeSummarizedFixture(rootPath: target.id, target: target)
        environment.scanService.yield(.finished(fixture.snapshot), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("full scan persisted") {
            await environment.cache.loadSnapshot(for: target) != nil
        }
        let fullScanInfo = try #require(model.cachedScanInfo[target.id])

        // Expand one folder; the spliced snapshot must reach the cache.
        let summarized = try #require(model.store?.node(id: fixture.summarized.id))
        model.expandSummarizedNode(summarized)
        try await waitUntilAsync("expansion scan started") {
            environment.scanService.scanCount == 2
        }
        let refreshed = makeRefreshedSubtreeSnapshot(directoryID: fixture.summarized.id)
        environment.scanService.yield(.finished(refreshed), scanIndex: 1)
        environment.scanService.finish(scanIndex: 1)

        try await waitUntilAsync("spliced snapshot persisted") {
            let cached = await environment.cache.loadSnapshot(for: target)
            return cached?.treeStore.node(id: fixture.summarized.id + "/new1.bin") != nil
        }

        // The cache index keeps the full scan's date and duration (a subtree
        // refresh predicts nothing about a full rescan); only the node count
        // reflects the splice, and the pre-splice snapshot rotated into the
        // previous slot.
        let splicedInfo = try #require(model.cachedScanInfo[target.id])
        #expect(splicedInfo.lastScanDate == fullScanInfo.lastScanDate)
        #expect(splicedInfo.lastScanDuration == fullScanInfo.lastScanDuration)
        #expect(splicedInfo.nodeCount == 4)
        #expect(splicedInfo.hasPreviousSnapshot)
        let previous = await environment.cache.loadPreviousSnapshot(for: target)
        #expect(previous?.treeStore.node(id: fixture.summarized.id)?.isAutoSummarized == true)
    }

    // MARK: - Fixtures

    private struct TestEnvironment {
        let cacheDirectory: URL
        let cache: ScanSnapshotCache
        let scanService: ControlledSubtreeScanService
        let pinnedFolderStore: PinnedFolderStore
        private let defaultsSuiteName: String

        init() throws {
            cacheDirectory = FileManager.default.temporaryDirectory
                .appending(path: "NeodiskSubtreeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            scanService = ControlledSubtreeScanService()
            defaultsSuiteName = "NeodiskSubtreeTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            pinnedFolderStore = PinnedFolderStore(defaults: defaults)
        }

        @MainActor
        func makeModel() -> NeodiskViewModel {
            NeodiskViewModel(
                coordinator: ScanCoordinator(
                    scanService: scanService,
                    progressThrottleDuration: .milliseconds(40)
                ),
                snapshotCache: cache,
                pinnedFolderStore: pinnedFolderStore
            )
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: cacheDirectory)
            UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    private struct SubtreeFixture {
        let snapshot: ScanSnapshot
        let directory: FileNodeRecord
        let file: FileNodeRecord
    }

    /// Root with one plain directory (containing old.bin) and one loose file.
    private func makeSubtreeFixture(rootPath: String, target: ScanTarget? = nil) -> SubtreeFixture {
        let oldFile = makeTestFileNode(id: rootPath + "/stuff/old.bin", name: "old.bin", size: 100)
        let directory = makeTestDirectoryNode(id: rootPath + "/stuff", name: "stuff", children: [oldFile])
        let looseFile = makeTestFileNode(id: rootPath + "/readme.txt", name: "readme.txt", size: 5)
        let root = makeTestDirectoryNode(id: rootPath, name: "root", children: [directory, looseFile])
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [directory, looseFile], directory.id: [oldFile]]
        )
        return SubtreeFixture(
            snapshot: makeTestSnapshot(target: target, root: root, store: store),
            directory: directory,
            file: looseFile
        )
    }

    private struct SummarizedFixture {
        let snapshot: ScanSnapshot
        let summarized: FileNodeRecord
    }

    private func makeSummarizedFixture(rootPath: String, target: ScanTarget? = nil) -> SummarizedFixture {
        let summarized = FileNodeRecord(
            id: rootPath + "/stuff",
            url: URL(filePath: rootPath + "/stuff", directoryHint: .isDirectory),
            name: "stuff",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 100,
            logicalSize: 100,
            descendantFileCount: 12,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true
        )
        let root = makeTestDirectoryNode(id: rootPath, name: "root", children: [summarized])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [summarized]])
        return SummarizedFixture(
            snapshot: makeTestSnapshot(target: target, root: root, store: store),
            summarized: summarized
        )
    }

    /// A fresh scan of the fixture directory: old.bin gone, two new files.
    private func makeRefreshedSubtreeSnapshot(directoryID: String) -> ScanSnapshot {
        let new1 = makeTestFileNode(id: directoryID + "/new1.bin", name: "new1.bin", size: 70)
        let new2 = makeTestFileNode(id: directoryID + "/new2.bin", name: "new2.bin", size: 30)
        let root = makeTestDirectoryNode(id: directoryID, name: "stuff", children: [new1, new2])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [new1, new2]])
        return makeTestSnapshot(root: root, store: store)
    }
}

/// Controlled scan stream that also records scan requests, so tests can
/// assert the target and options of a subtree scan. Local to this suite —
/// the equivalents in other test files are file-private.
private final class ControlledSubtreeScanService: ScanEventStreaming, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<ScanProgressEvent, Error>.Continuation

    private let lock = NSLock()
    private var continuations: [Continuation] = []
    private var recordedRequests: [(target: ScanTarget, options: ScanOptions)] = []

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            continuations.append(continuation)
            recordedRequests.append((target, options))
            lock.unlock()
        }
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    var requests: [(target: ScanTarget, options: ScanOptions)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func yield(_ event: ScanProgressEvent, scanIndex: Int) {
        continuation(at: scanIndex)?.yield(event)
    }

    func finish(scanIndex: Int, throwing error: Error? = nil) {
        continuation(at: scanIndex)?.finish(throwing: error)
    }

    private func continuation(at index: Int) -> Continuation? {
        lock.lock()
        defer { lock.unlock() }
        guard continuations.indices.contains(index) else { return nil }
        return continuations[index]
    }
}

@MainActor
private func waitUntilAsync(
    _ description: String,
    timeout: TimeInterval = 2,
    condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() >= deadline {
            Issue.record("Timed out waiting for \(description).")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
