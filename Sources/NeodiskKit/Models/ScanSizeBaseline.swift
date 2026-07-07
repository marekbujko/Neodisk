//
//  ScanSizeBaseline.swift
//  Neodisk
//
//  Compact per-node allocated sizes of a previous snapshot — the baseline
//  for "what grew since the last scan" comparisons against the current one.
//

import Foundation

/// Node IDs are stored as 64-bit FNV-1a hashes so a million-node baseline
/// costs ~16 bytes per node instead of retaining every path string; a hash
/// collision (odds around 1e-7 for a two-million-node tree) at worst shows
/// one wrong delta.
public struct ScanSizeBaseline: Sendable {
    /// Target the baseline belongs to; deltas against other targets are
    /// meaningless.
    public let targetID: String
    /// When the baseline scan finished, for "changes since …" labels.
    public let finishedAt: Date?
    private let sizeByHashedID: [UInt64: Int64]

    public init(snapshot: ScanSnapshot) {
        targetID = snapshot.target.id
        finishedAt = snapshot.finishedAt
        var sizes = [UInt64: Int64](minimumCapacity: snapshot.treeStore.nodeCount)
        for node in snapshot.treeStore.allNodes {
            sizes[Self.hashedID(node.id)] = node.allocatedSize
        }
        sizeByHashedID = sizes
    }

    /// The allocated size the node had in the baseline scan, or nil when it
    /// didn't exist then (it is new).
    public func allocatedSize(forNodeID id: String) -> Int64? {
        sizeByHashedID[Self.hashedID(id)]
    }

    /// Growth of a node since the baseline scan; a node absent from the
    /// baseline counts its full size as growth.
    public func sizeDelta(for node: FileNodeRecord) -> Int64 {
        node.allocatedSize - (allocatedSize(forNodeID: node.id) ?? 0)
    }

    private static func hashedID(_ id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
