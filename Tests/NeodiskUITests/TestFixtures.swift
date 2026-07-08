import Foundation
import NeodiskKit

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
