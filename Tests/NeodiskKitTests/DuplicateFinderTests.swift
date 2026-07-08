import Foundation
import Testing
@testable import NeodiskKit

/// Exercises the finder against real files in a temp directory: hashing
/// reads actual contents, so fixtures live on disk.
@Suite struct DuplicateFinderTests {
    private static let megabyte = 1 << 20

    /// Contents big enough to clear the 1 MB minimum and (for the
    /// full-hash cases) the 256 KB prefix.
    private func bytes(seed: UInt8, count: Int, tailSeed: UInt8? = nil) -> Data {
        var data = Data(repeating: seed, count: count)
        if let tailSeed {
            // Same prefix, different tail: forces the full-content pass to
            // tell files apart.
            data.replaceSubrange((count - 16)..<count, with: Data(repeating: tailSeed, count: 16))
        }
        return data
    }

    private func makeStore(directory: URL, files: [(name: String, data: Data)]) throws -> FileTreeStore {
        var children: [FileNodeRecord] = []
        for file in files {
            let url = directory.appending(path: file.name)
            try file.data.write(to: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let inode = (attributes[.systemFileNumber] as? UInt64)
                ?? UInt64(attributes[.systemFileNumber] as? Int ?? 0)
            children.append(FileNodeRecord(
                id: url.path,
                url: url,
                name: file.name,
                isDirectory: false,
                isSymbolicLink: false,
                allocatedSize: Int64(file.data.count),
                logicalSize: Int64(file.data.count),
                descendantFileCount: 1,
                lastModified: nil,
                fileIdentity: FileIdentity(device: 1, inode: inode),
                isPackage: false,
                isAccessible: true,
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false
            ))
        }
        let root = FileNodeRecord.directory(
            id: directory.path,
            url: directory,
            name: directory.lastPathComponent,
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        return FileTreeStore(
            root: root,
            childrenByID: [directory.path: FileTreeStore.sortedChildren(children)]
        )
    }

    private func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "neodisk-dupes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    @Test func findsIdenticalFilesAndSkipsSameSizeDifferentContent() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0xAB, count: 2 * Self.megabyte)
            let store = try makeStore(directory: directory, files: [
                ("copy-1.bin", identical),
                ("copy-2.bin", identical),
                ("same-size-other.bin", bytes(seed: 0xCD, count: 2 * Self.megabyte)),
                ("unique.bin", bytes(seed: 0xEF, count: 3 * Self.megabyte)),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.count == 1)
            let group = try #require(results.groups.first)
            #expect(group.nodeIDs.map { ($0 as NSString).lastPathComponent }.sorted()
                == ["copy-1.bin", "copy-2.bin"])
            #expect(group.fileSize == Int64(2 * Self.megabyte))
            #expect(group.wastedBytes == Int64(2 * Self.megabyte))
            #expect(results.totalWastedBytes == group.wastedBytes)
            #expect(results.unreadableCount == 0)
        }
    }

    @Test func identicalPrefixDifferentTailIsNotADuplicate() async throws {
        try await withTempDirectory { directory in
            // Same size and same first 256 KB, so both survive the prefix
            // pass; only the full-content hash can separate them.
            let store = try makeStore(directory: directory, files: [
                ("prefix-twin-1.bin", bytes(seed: 0x11, count: 2 * Self.megabyte, tailSeed: 0x22)),
                ("prefix-twin-2.bin", bytes(seed: 0x11, count: 2 * Self.megabyte, tailSeed: 0x33)),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.isEmpty)
            #expect(results.candidateCount == 2)
        }
    }

    @Test func filesBelowMinimumSizeAreIgnored() async throws {
        try await withTempDirectory { directory in
            let small = bytes(seed: 0x42, count: 4096)
            let store = try makeStore(directory: directory, files: [
                ("small-1.bin", small),
                ("small-2.bin", small),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.isEmpty)
            #expect(results.candidateCount == 0)
        }
    }

    @Test func hardLinksCollapseToOneCopy() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0x7A, count: 2 * Self.megabyte)
            var store = try makeStore(directory: directory, files: [
                ("original.bin", identical),
                ("real-copy.bin", identical),
            ])

            // A hard link to original.bin: same content, same file identity —
            // it must not count as a third copy.
            let linkURL = directory.appending(path: "hard-link.bin")
            let originalURL = directory.appending(path: "original.bin")
            try FileManager.default.linkItem(at: originalURL, to: linkURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: originalURL.path)
            let inode = (attributes[.systemFileNumber] as? UInt64)
                ?? UInt64(attributes[.systemFileNumber] as? Int ?? 0)
            let linkNode = FileNodeRecord(
                id: linkURL.path,
                url: linkURL,
                name: "hard-link.bin",
                isDirectory: false,
                isSymbolicLink: false,
                allocatedSize: Int64(identical.count),
                logicalSize: Int64(identical.count),
                descendantFileCount: 1,
                lastModified: nil,
                fileIdentity: FileIdentity(device: 1, inode: inode),
                linkCount: 2,
                isPackage: false,
                isAccessible: true,
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false
            )
            var children = store.children(of: directory.path)
            children.append(linkNode)
            let root = FileNodeRecord.directory(
                id: directory.path,
                url: directory,
                name: directory.lastPathComponent,
                children: children,
                lastModified: nil,
                isPackage: false,
                isAccessible: true
            )
            store = FileTreeStore(
                root: root,
                childrenByID: [directory.path: FileTreeStore.sortedChildren(children)]
            )

            let results = try await DuplicateFinder.findDuplicates(in: store)

            let group = try #require(results.groups.first)
            #expect(results.groups.count == 1)
            // Two distinct on-disk files, not three paths.
            #expect(group.nodeIDs.count == 2)
        }
    }

    @Test func vanishedFileCountsAsUnreadable() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0x55, count: 2 * Self.megabyte)
            let store = try makeStore(directory: directory, files: [
                ("kept-1.bin", identical),
                ("kept-2.bin", identical),
                ("vanished-1.bin", bytes(seed: 0x66, count: 2 * Self.megabyte)),
                ("vanished-2.bin", bytes(seed: 0x66, count: 2 * Self.megabyte)),
            ])
            try FileManager.default.removeItem(at: directory.appending(path: "vanished-1.bin"))
            try FileManager.default.removeItem(at: directory.appending(path: "vanished-2.bin"))

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.count == 1)
            #expect(results.unreadableCount == 2)
        }
    }

    @Test func reportsMonotonicProgressEndingAtOne() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0x99, count: 2 * Self.megabyte)
            let store = try makeStore(directory: directory, files: [
                ("p1.bin", identical),
                ("p2.bin", identical),
                ("p3.bin", bytes(seed: 0x98, count: 2 * Self.megabyte)),
            ])

            let collector = ProgressCollector()
            _ = try await DuplicateFinder.findDuplicates(in: store) { progress in
                collector.record(progress.fractionCompleted)
            }

            let fractions = collector.fractions()
            #expect(!fractions.isEmpty)
            #expect(fractions == fractions.sorted())
            #expect(fractions.last == 1.0)
        }
    }
}

/// Progress callbacks arrive from an arbitrary executor; collect behind a
/// lock so the test can assert on the sequence.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func fractions() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
