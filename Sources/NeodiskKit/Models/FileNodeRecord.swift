//
//  FileNodeRecord.swift
//  Neodisk
//

import Foundation

public struct FileNodeRecord: Identifiable, Sendable {
    public let id: String
    /// Absolute filesystem path. The record stores the path string rather
    /// than a URL: URL construction measurably dominates decoding
    /// million-node snapshots, and most consumers only need the string.
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let allocatedSize: Int64
    public let unduplicatedAllocatedSize: Int64
    public let logicalSize: Int64
    public let descendantFileCount: Int
    public let lastModified: Date?
    public let fileIdentity: FileIdentity?
    public let linkCount: UInt64
    public let isPackage: Bool
    public let isAccessible: Bool
    public let isSelfAccessible: Bool
    public let isSynthetic: Bool
    public let isAutoSummarized: Bool

    /// URL form of `path`. Computed on demand — see `path`.
    public nonisolated var url: URL {
        URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    /// Path extension without URL construction, matching
    /// `URL.pathExtension` semantics via `NSString.pathExtension`.
    public nonisolated var pathExtension: String {
        (path as NSString).pathExtension
    }

    public nonisolated init(
        id: String,
        url: URL,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        allocatedSize: Int64,
        unduplicatedAllocatedSize: Int64? = nil,
        logicalSize: Int64,
        descendantFileCount: Int,
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        isPackage: Bool,
        isAccessible: Bool,
        isSelfAccessible: Bool,
        isSynthetic: Bool,
        isAutoSummarized: Bool
    ) {
        self.init(
            id: id,
            path: url.path,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized
        )
    }

    public nonisolated init(
        id: String,
        path: String,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        allocatedSize: Int64,
        unduplicatedAllocatedSize: Int64? = nil,
        logicalSize: Int64,
        descendantFileCount: Int,
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        isPackage: Bool,
        isAccessible: Bool,
        isSelfAccessible: Bool,
        isSynthetic: Bool,
        isAutoSummarized: Bool
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.allocatedSize = allocatedSize
        self.unduplicatedAllocatedSize = unduplicatedAllocatedSize ?? allocatedSize
        self.logicalSize = logicalSize
        self.descendantFileCount = descendantFileCount
        self.lastModified = lastModified
        self.fileIdentity = fileIdentity
        self.linkCount = linkCount
        self.isPackage = isPackage
        self.isAccessible = isAccessible
        self.isSelfAccessible = isSelfAccessible
        self.isSynthetic = isSynthetic
        self.isAutoSummarized = isAutoSummarized
    }

    nonisolated var itemKind: String {
        if isSynthetic {
            return "System Data"
        }
        if isAutoSummarized {
            return "Summarized"
        }
        if isSymbolicLink {
            return "Alias"
        }
        if isPackage {
            return "Package"
        }
        return isDirectory ? "Folder" : "File"
    }

    public nonisolated var supportsFileActions: Bool {
        !isSynthetic
    }

    public nonisolated static func directory(
        id: String,
        url: URL,
        name: String,
        children: [FileNodeRecord],
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        isPackage: Bool,
        isAccessible: Bool,
        childrenAreSorted: Bool = false
    ) -> FileNodeRecord {
        let sortedChildren = childrenAreSorted ? children : FileTreeStore.sortedChildren(children)
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var descendantFileCount = 0
        var childrenAreAccessible = true
        for child in sortedChildren {
            allocatedSize = allocatedSize.addingClamped(child.allocatedSize)
            logicalSize = logicalSize.addingClamped(child.logicalSize)
            childrenAreAccessible = childrenAreAccessible && child.isAccessible
            if child.isDirectory {
                descendantFileCount += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                descendantFileCount += 1
            }
        }
        let isFullyAccessible = isAccessible && childrenAreAccessible

        return FileNodeRecord(
            id: id,
            url: url,
            name: name,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isFullyAccessible,
            isSelfAccessible: isAccessible,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }
}

extension Int64 {
    /// Saturating addition for file-size accumulation. Buggy filesystem
    /// drivers can report pathological sizes; summing those must degrade to
    /// a clamped number, never trap the whole app.
    nonisolated func addingClamped(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}

extension FileNodeRecord {
    var secondaryStatusText: String? {
        if isSynthetic {
            return "Estimated from volume usage"
        }
        if isAutoSummarized {
            return "Summarized (\(descendantFileCount) files)"
        }
        if !isAccessible {
            return "Limited access"
        }
        return nil
    }

    var accessDescription: String {
        if isSynthetic {
            return "Estimated"
        }
        return isAccessible ? "Readable" : "Limited"
    }

}
