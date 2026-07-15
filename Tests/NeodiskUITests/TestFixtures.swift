import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Tears down a per-test UserDefaults suite without leaving a plist behind.
/// removePersistentDomain alone is not enough: cfprefsd answers it by
/// persisting an *empty* domain, so every test run used to leave another
/// `<SuiteName>-<UUID>.plist` in ~/Library/Preferences. Flush, then delete
/// the backing file too.
func removeTestDefaultsSuite(_ defaults: UserDefaults, named suiteName: String) {
    defaults.removePersistentDomain(forName: suiteName)
    defaults.synchronize()
    let plist = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Preferences/\(suiteName).plist")
    try? FileManager.default.removeItem(at: plist)
}

func makeTestTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}

func makeTestFileNode(
    id: String,
    name: String,
    size: Int64 = 1,
    unduplicatedAllocatedSize: Int64? = nil,
    lastModified: Date? = nil,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        unduplicatedAllocatedSize: unduplicatedAllocatedSize,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: lastModified,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

func makeTestDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord],
    isPackage: Bool = false,
    isAccessible: Bool = true,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1
) -> FileNodeRecord {
    FileNodeRecord.directory(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        children: children,
        lastModified: nil,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        isPackage: isPackage,
        isAccessible: isAccessible
    )
}

func makeTestSnapshot(
    target: ScanTarget? = nil,
    root: FileNodeRecord,
    store: FileTreeStore,
    warnings: [ScanWarning] = [],
    startedAt: Date = Date(),
    finishedAt: Date = Date()
) -> ScanSnapshot {
    ScanSnapshot(
        target: target ?? ScanTarget(url: root.url),
        treeStore: store,
        startedAt: startedAt,
        finishedAt: finishedAt,
        scanWarnings: warnings,
        aggregateStats: store.aggregateStats,
        isComplete: true
    )
}

// MARK: - Controlled scan stream

struct ControlledScanRequest {
    let target: ScanTarget
    let options: ScanOptions
}

/// Hand-driven ScanEventStreaming fake shared by the coordinator and view
/// model suites: tests yield events per scan index instead of scanning disk,
/// and can assert the requests made and stream terminations observed.
final class ControlledScanService: ScanEventStreaming, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<ScanProgressEvent, Error>.Continuation

    private let lock = NSLock()
    private var continuations: [Continuation] = []
    private var storedRequests: [ControlledScanRequest] = []
    private var storedTerminationCount = 0

    var requests: [ControlledScanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    var terminationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedTerminationCount
    }

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            continuations.append(continuation)
            storedRequests.append(ControlledScanRequest(target: target, options: options))
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.storedTerminationCount += 1
                self.lock.unlock()
            }
        }
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

// MARK: - Eventual-state assertions

/// Polls until the condition holds, recording a test failure on timeout.
/// The async-condition form; the sync overload below forwards here.
@MainActor
func waitUntilAsync(
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

@MainActor
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 2,
    condition: () -> Bool
) async throws {
    try await waitUntilAsync(description, timeout: timeout, condition: condition)
}
