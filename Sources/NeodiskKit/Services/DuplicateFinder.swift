//
//  DuplicateFinder.swift
//  Neodisk
//
//  Finds files with identical content in a scanned tree: group by size,
//  then confirm candidates by hashing — a 256 KB prefix hash first, a full
//  content hash only where prefixes collide — so the disk reads stay
//  proportional to plausible duplicates, not to the scan. Hard links are
//  one file, not duplicates, and are collapsed by file identity up front.
//
//  Read-only like everything else in the engine: files are opened for
//  reading, nothing is modified.
//

import CryptoKit
import Darwin
import Foundation

/// One set of files whose contents are byte-identical.
public struct DuplicateGroup: Sendable, Equatable, Identifiable {
    /// Content-derived: the confirming hash plus the file size.
    public let id: String
    /// Logical size of each copy.
    public let fileSize: Int64
    /// Node IDs (absolute paths) of the copies, sorted, one per distinct
    /// on-disk file — hard-linked aliases are already collapsed.
    public let nodeIDs: [String]

    /// Bytes freed by keeping one copy and deleting the rest.
    public var wastedBytes: Int64 {
        fileSize * Int64(nodeIDs.count - 1)
    }

    public init(id: String, fileSize: Int64, nodeIDs: [String]) {
        self.id = id
        self.fileSize = fileSize
        self.nodeIDs = nodeIDs
    }
}

public struct DuplicateScanResults: Sendable, Equatable {
    /// Confirmed groups, biggest waste first.
    public let groups: [DuplicateGroup]
    public let totalWastedBytes: Int64
    /// Files that survived size grouping and were considered for hashing.
    public let candidateCount: Int
    /// Candidates dropped because their contents couldn't be read (moved,
    /// deleted, or protected since the scan).
    public let unreadableCount: Int

    public init(groups: [DuplicateGroup], totalWastedBytes: Int64, candidateCount: Int, unreadableCount: Int) {
        self.groups = groups
        self.totalWastedBytes = totalWastedBytes
        self.candidateCount = candidateCount
        self.unreadableCount = unreadableCount
    }
}

public struct DuplicateScanProgress: Sendable, Equatable {
    /// Monotonic 0...1 across both hashing passes, weighted by bytes read.
    public let fractionCompleted: Double

    public init(fractionCompleted: Double) {
        self.fractionCompleted = fractionCompleted
    }
}

public enum DuplicateFinder {
    /// Files below this size are ignored: small files duplicate constantly
    /// (configs, icons, node_modules) and reclaim next to nothing.
    public static let defaultMinimumFileSize: Int64 = 1 << 20 // 1 MB

    /// Prefix length of the first-pass hash.
    static let prefixHashLength = 1 << 18 // 256 KB
    /// Streaming chunk size of the full-content pass.
    private static let fullHashChunkSize = 1 << 22 // 4 MB
    /// Concurrent hashing width — enough to keep an SSD busy without
    /// starving the rest of the app of I/O.
    private static let maxConcurrentReads = 6

    /// Scans a tree store for content-identical files. Runs entirely off
    /// the snapshot plus fresh reads of the candidate files; cancellation
    /// (via the surrounding task) throws `CancellationError`. `onProgress`
    /// is called on an arbitrary executor with a monotonic fraction.
    public static func findDuplicates(
        in store: FileTreeStore,
        minimumFileSize: Int64 = defaultMinimumFileSize,
        onProgress: (@Sendable (DuplicateScanProgress) -> Void)? = nil
    ) async throws -> DuplicateScanResults {
        // 1. Same-size grouping over the snapshot — no I/O yet. Only real,
        // readable files count: directories (incl. packages), symlinks, and
        // synthetic nodes never join a group.
        var bySize: [Int64: [FileNodeRecord]] = [:]
        for node in store.allNodes {
            guard !node.isDirectory, !node.isSymbolicLink, !node.isSynthetic,
                  node.isSelfAccessible, node.logicalSize >= minimumFileSize else { continue }
            bySize[node.logicalSize, default: []].append(node)
        }

        // 2. Collapse hard links: aliases of one on-disk file share a
        // FileIdentity and are one copy, not duplicates. Groups need two
        // distinct files to stay interesting.
        var candidates: [(size: Int64, nodes: [FileNodeRecord])] = []
        for (size, nodes) in bySize where nodes.count >= 2 {
            var seenIdentities = Set<FileIdentity>()
            var distinct: [FileNodeRecord] = []
            for node in nodes {
                if let identity = node.fileIdentity {
                    guard seenIdentities.insert(identity).inserted else { continue }
                }
                distinct.append(node)
            }
            if distinct.count >= 2 {
                candidates.append((size, distinct))
            }
        }

        // 2b. Drop candidates whose bytes we must not, or cannot, read before
        // any file is opened. Cloud placeholders (SF_DATALESS: iCloud, Google
        // Drive, OneDrive and other File Providers) block on read while the
        // provider materializes them from the network — slowly, or forever
        // when offline or throttled — and that read has no cancellation
        // escape, so a handful of them wedge every hashing worker and the
        // scan stops progressing. Non-regular files (fifo/socket/device) and
        // files that vanished since the scan can't be hashed either. A
        // metadata-only stat decides all three without opening the file, so a
        // stalled provider can never wedge a worker. A group needs two
        // distinct readable files left to stay interesting.
        var skippedUnhashable = 0
        var readableCandidates: [(size: Int64, nodes: [FileNodeRecord])] = []
        readableCandidates.reserveCapacity(candidates.count)
        for (size, nodes) in candidates {
            try Task.checkCancellation()
            var readable: [FileNodeRecord] = []
            for node in nodes {
                if isHashable(node.path) {
                    readable.append(node)
                } else {
                    skippedUnhashable += 1
                }
            }
            if readable.count >= 2 {
                readableCandidates.append((size, readable))
            }
        }
        candidates = readableCandidates

        let candidateCount = candidates.reduce(0) { $0 + $1.nodes.count }

        // Progress is bytes-based and monotonic: the planned total starts
        // pessimistic (prefix pass + full pass for every candidate) and only
        // ever shrinks as the prefix pass rules files out, so the fraction
        // never moves backwards.
        let progress = ProgressAccounting(
            plannedBytes: candidates.reduce(Int64(0)) { total, group in
                let prefixBytes = min(group.size, Int64(prefixHashLength)) * Int64(group.nodes.count)
                let fullBytes = group.size > Int64(prefixHashLength)
                    ? group.size * Int64(group.nodes.count)
                    : 0
                return total + prefixBytes + fullBytes
            },
            onProgress: onProgress
        )

        // 3. Prefix-hash pass over every candidate.
        let prefixResults = try await hashConcurrently(
            candidates.flatMap { group in group.nodes.map { (node: $0, size: group.size) } }
        ) { node, size in
            let digest = try hashPrefix(of: node.path)
            let read = min(size, Int64(prefixHashLength))
            await progress.add(bytes: read)
            return digest
        }
        var unreadableCount = skippedUnhashable + prefixResults.unreadable.count
        await progress.drop(bytes: prefixResults.unreadable.reduce(Int64(0)) {
            // A file that failed its prefix read won't get a full pass either.
            $0 + ($1.size > Int64(prefixHashLength) ? $1.size : 0)
        })

        // Regroup by (size, prefix hash); small files are fully covered by
        // the prefix and confirm here.
        var confirmed: [DuplicateGroup] = []
        var needFullHash: [(node: FileNodeRecord, size: Int64)] = []
        var subgroups: [String: [(node: FileNodeRecord, size: Int64)]] = [:]
        for entry in prefixResults.hashed {
            subgroups["\(entry.size)-\(entry.digest)", default: []].append((entry.node, entry.size))
        }
        for (key, members) in subgroups {
            if members.count < 2 {
                await progress.drop(bytes: members.reduce(Int64(0)) {
                    $0 + ($1.size > Int64(prefixHashLength) ? $1.size : 0)
                })
                continue
            }
            if members[0].size <= Int64(prefixHashLength) {
                confirmed.append(DuplicateGroup(
                    id: key,
                    fileSize: members[0].size,
                    nodeIDs: members.map(\.node.id).sorted()
                ))
            } else {
                needFullHash.append(contentsOf: members)
            }
        }

        // 4. Full-content pass only where prefixes collided.
        let fullResults = try await hashConcurrently(needFullHash) { node, size in
            let digest = try await hashFullContents(of: node.path) { chunkBytes in
                await progress.add(bytes: chunkBytes)
            }
            _ = size
            return digest
        }
        unreadableCount += fullResults.unreadable.count

        var fullGroups: [String: [(node: FileNodeRecord, size: Int64)]] = [:]
        for entry in fullResults.hashed {
            fullGroups["\(entry.size)-\(entry.digest)", default: []].append((entry.node, entry.size))
        }
        for (key, members) in fullGroups where members.count >= 2 {
            confirmed.append(DuplicateGroup(
                id: key,
                fileSize: members[0].size,
                nodeIDs: members.map(\.node.id).sorted()
            ))
        }

        await progress.finish()

        confirmed.sort {
            if $0.wastedBytes != $1.wastedBytes { return $0.wastedBytes > $1.wastedBytes }
            return $0.id < $1.id
        }
        return DuplicateScanResults(
            groups: confirmed,
            totalWastedBytes: confirmed.reduce(0) { $0 + $1.wastedBytes },
            candidateCount: candidateCount,
            unreadableCount: unreadableCount
        )
    }

    // MARK: - Hashing

    private struct HashPassResults {
        var hashed: [(node: FileNodeRecord, size: Int64, digest: String)] = []
        var unreadable: [(node: FileNodeRecord, size: Int64)] = []
    }

    /// Runs `work` over the entries with bounded concurrency; a thrown
    /// non-cancellation error marks the entry unreadable instead of failing
    /// the scan.
    private static func hashConcurrently(
        _ entries: [(node: FileNodeRecord, size: Int64)],
        work: @escaping @Sendable (FileNodeRecord, Int64) async throws -> String
    ) async throws -> HashPassResults {
        var results = HashPassResults()
        try await withThrowingTaskGroup(
            of: (node: FileNodeRecord, size: Int64, digest: String?).self
        ) { group in
            var iterator = entries.makeIterator()
            var inFlight = 0

            func addNext() -> Bool {
                guard let entry = iterator.next() else { return false }
                group.addTask {
                    do {
                        let digest = try await work(entry.node, entry.size)
                        return (entry.node, entry.size, digest)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (entry.node, entry.size, nil)
                    }
                }
                return true
            }

            while inFlight < maxConcurrentReads, addNext() { inFlight += 1 }
            while let finished = try await group.next() {
                inFlight -= 1
                if let digest = finished.digest {
                    results.hashed.append((finished.node, finished.size, digest))
                } else {
                    results.unreadable.append((finished.node, finished.size))
                }
                try Task.checkCancellation()
                if addNext() { inFlight += 1 }
            }
        }
        return results
    }

    /// `st_flags` bit set on File Provider placeholders whose contents are
    /// not materialized locally (sys/stat.h `SF_DATALESS`). Reading such a
    /// file forces a network download; we refuse to, so a paused or offline
    /// provider can't stall the scan.
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// Metadata-only readiness gate: a candidate is safe to hash only when
    /// it's a regular file whose bytes are on disk right now. `stat` touches
    /// inode metadata alone — it never opens the file, never blocks on a
    /// provider, and never triggers a download.
    private static func isHashable(_ path: String) -> Bool {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return false }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return false }
        return info.st_flags & datalessFlag == 0
    }

    private static func hashPrefix(of path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(filePath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: prefixHashLength) ?? Data()
        return SHA256.hash(data: data).hexString
    }

    private static func hashFullContents(
        of path: String,
        onChunk: (Int64) async -> Void
    ) async throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(filePath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: fullHashChunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
            await onChunk(Int64(chunk.count))
        }
        return hasher.finalize().hexString
    }
}

/// Serializes byte counters for the two hashing passes and forwards a
/// throttled, monotonic fraction to the caller.
private actor ProgressAccounting {
    private var plannedBytes: Int64
    private var completedBytes: Int64 = 0
    private var lastReportedFraction = 0.0
    private let onProgress: (@Sendable (DuplicateScanProgress) -> Void)?

    init(plannedBytes: Int64, onProgress: (@Sendable (DuplicateScanProgress) -> Void)?) {
        self.plannedBytes = max(plannedBytes, 1)
        self.onProgress = onProgress
    }

    func add(bytes: Int64) {
        completedBytes += bytes
        report()
    }

    /// Work that turned out unnecessary (prefix pass ruled the file out):
    /// shrinking the plan keeps the fraction meaningful without ever moving
    /// it backwards.
    func drop(bytes: Int64) {
        plannedBytes = max(plannedBytes - bytes, completedBytes, 1)
        report()
    }

    func finish() {
        completedBytes = plannedBytes
        report(force: true)
    }

    private func report(force: Bool = false) {
        guard let onProgress else { return }
        let fraction = min(1, Double(completedBytes) / Double(plannedBytes))
        guard force || fraction - lastReportedFraction >= 0.01 else { return }
        lastReportedFraction = fraction
        onProgress(DuplicateScanProgress(fractionCompleted: fraction))
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
