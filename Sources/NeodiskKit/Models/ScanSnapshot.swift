//
//  ScanSnapshot.swift
//  Neodisk
//

import Foundation

public enum ScanWarningCategory: String, Hashable, Sendable {
    case permissionDenied
    case fileSystem
}

public struct ScanWarning: Identifiable, Hashable, Sendable {
    public let path: String
    public let message: String
    public let category: ScanWarningCategory

    /// Content-derived, so identical warnings are equal — they dedupe
    /// naturally and keep their identity across a snapshot codec round
    /// trip. (A stored UUID made two identical warnings never equal.)
    public nonisolated var id: String {
        [category.rawValue, path, message].joined(separator: "\u{0}")
    }

    public init(path: String, message: String, category: ScanWarningCategory) {
        self.path = path
        self.message = message
        self.category = category
    }
}

public struct ScanAggregateStats: Sendable {
    public let totalAllocatedSize: Int64
    public let totalLogicalSize: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let accessibleItemCount: Int
    public let inaccessibleItemCount: Int

    public init(
        totalAllocatedSize: Int64,
        totalLogicalSize: Int64,
        fileCount: Int,
        directoryCount: Int,
        accessibleItemCount: Int,
        inaccessibleItemCount: Int
    ) {
        self.totalAllocatedSize = totalAllocatedSize
        self.totalLogicalSize = totalLogicalSize
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.accessibleItemCount = accessibleItemCount
        self.inaccessibleItemCount = inaccessibleItemCount
    }
}

public nonisolated enum ScanArchivePathMode: String, Codable, Sendable {
    case absolute

    public var allowsArchivedPathCopy: Bool {
        switch self {
        case .absolute:
            return true
        }
    }
}

public nonisolated enum ImportedSnapshotLiveActionCapability: String, Codable, Sendable {
    case disabled
    case pathValidation
}

public nonisolated struct ImportedSnapshotContext: Sendable {
    public let sourceURL: URL
    public let importedAt: Date
    public let pathMode: ScanArchivePathMode
    public let liveActionCapability: ImportedSnapshotLiveActionCapability

    public nonisolated init(
        sourceURL: URL,
        importedAt: Date = Date(),
        pathMode: ScanArchivePathMode,
        liveActionCapability: ImportedSnapshotLiveActionCapability
    ) {
        self.sourceURL = sourceURL
        self.importedAt = importedAt
        self.pathMode = pathMode
        self.liveActionCapability = liveActionCapability
    }
}

public nonisolated enum ScanSnapshotSource: Sendable {
    case live
    case imported(ImportedSnapshotContext)

    public nonisolated var isImported: Bool {
        if case .imported = self {
            return true
        }
        return false
    }

    public nonisolated var allowsLivePathActions: Bool {
        switch self {
        case .live:
            return true
        case .imported(let context):
            return context.liveActionCapability == .pathValidation
        }
    }

    public nonisolated var allowsArchivedPathCopy: Bool {
        switch self {
        case .live:
            return true
        case .imported(let context):
            return context.pathMode.allowsArchivedPathCopy
        }
    }

    /// Whether the snapshot may enter the on-disk scan cache (and thereby
    /// participate in "changes since last scan" diffing). Imported archives
    /// are view-only: caching one would overwrite the location's real scan
    /// history.
    public nonisolated var isPersistable: Bool {
        switch self {
        case .live:
            return true
        case .imported:
            return false
        }
    }
}

public struct ScanSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let target: ScanTarget
    public let treeStore: FileTreeStore
    public let startedAt: Date
    public let finishedAt: Date?
    public let scanWarnings: [ScanWarning]
    public let aggregateStats: ScanAggregateStats
    public let isComplete: Bool
    public let scanOptions: ScanOptions?
    public let source: ScanSnapshotSource

    public nonisolated init(
        id: UUID = UUID(),
        target: ScanTarget,
        treeStore: FileTreeStore,
        startedAt: Date,
        finishedAt: Date?,
        scanWarnings: [ScanWarning],
        aggregateStats: ScanAggregateStats,
        isComplete: Bool,
        scanOptions: ScanOptions? = nil,
        source: ScanSnapshotSource = .live
    ) {
        self.id = id
        self.target = target
        self.treeStore = treeStore
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.scanWarnings = scanWarnings
        self.aggregateStats = aggregateStats
        self.isComplete = isComplete
        self.scanOptions = scanOptions
        self.source = source
    }

    public nonisolated var root: FileNodeRecord {
        treeStore.root
    }

    public nonisolated func removingNode(id targetID: String) -> ScanSnapshot? {
        try? removingNode(id: targetID, cancellationCheck: {})
    }

    public nonisolated func removingNode(
        id targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> ScanSnapshot? {
        try cancellationCheck()
        guard let updatedStore = try treeStore.removingSubtree(
            id: targetID,
            cancellationCheck: cancellationCheck
        ) else { return nil }

        return ScanSnapshot(
            id: id,
            target: target,
            treeStore: updatedStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: scanWarnings,
            aggregateStats: updatedStore.aggregateStats,
            isComplete: isComplete,
            scanOptions: scanOptions,
            source: source
        )
    }

    public nonisolated func replacingNode(
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = []
    ) -> ScanSnapshot? {
        try? replacingNode(
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {}
        )
    }

    public nonisolated func replacingNode(
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = [],
        cancellationCheck: () throws -> Void
    ) throws -> ScanSnapshot? {
        try cancellationCheck()
        guard let updatedStore = try treeStore.replacingSubtree(
            id: targetID,
            with: replacement,
            cancellationCheck: cancellationCheck
        ) else { return nil }

        return ScanSnapshot(
            target: target,
            treeStore: updatedStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: Self.mergedWarnings(existing: scanWarnings, additional: additionalWarnings),
            aggregateStats: updatedStore.aggregateStats,
            isComplete: isComplete,
            scanOptions: scanOptions,
            source: source
        )
    }

    public nonisolated func scoped(to target: ScanTarget) -> ScanSnapshot? {
        try? scoped(to: target, cancellationCheck: {})
    }

    public nonisolated func scoped(
        to target: ScanTarget,
        cancellationCheck: () throws -> Void
    ) throws -> ScanSnapshot? {
        try cancellationCheck()
        guard let scopedStore = try treeStore.subtree(
            rootedAt: target.id,
            cancellationCheck: cancellationCheck
        ) else { return nil }

        var scopedWarnings: [ScanWarning] = []
        scopedWarnings.reserveCapacity(scanWarnings.count)
        for warning in scanWarnings {
            try cancellationCheck()
            if Self.path(warning.path, isContainedIn: target.id) {
                scopedWarnings.append(warning)
            }
        }

        return ScanSnapshot(
            target: target,
            treeStore: scopedStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: scopedWarnings,
            aggregateStats: scopedStore.aggregateStats,
            isComplete: isComplete,
            scanOptions: scanOptions,
            source: source
        )
    }

    private nonisolated static func mergedWarnings(
        existing: [ScanWarning],
        additional: [ScanWarning]
    ) -> [ScanWarning] {
        var seen = Set<String>()
        var result: [ScanWarning] = []

        for warning in existing + additional where seen.insert(warning.id).inserted {
            result.append(warning)
        }

        return result
    }

    private nonisolated static func path(_ path: String, isContainedIn rootPath: String) -> Bool {
        guard rootPath != "/" else { return true }
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
