//
//  DuplicatesModel.swift
//  Neodisk
//
//  Duplicate-finder state for the statistics panel's Duplicates tab: a
//  content scan of the displayed snapshot, its results, and the drill-in
//  into one duplicate group. Owned by NeodiskViewModel as
//  `model.duplicates`. Hashing costs real I/O, so it only runs asked-for:
//  via the Find Duplicates button, or right after a scan when the opt-in
//  "find duplicates automatically" preference is on.
//
//  A finished run is persisted through the snapshot cache's `.nddup` slot so
//  reopening the tab (this launch or after relaunch) shows the previous
//  result without re-hashing. Loading is snapshot-scoped like everything
//  else and never triggers hashing on its own.
//
//  Read-only, like the app promises: the finder only reads file contents;
//  cleaning up happens in Finder.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class DuplicatesModel {
    enum Phase {
        case idle
        case scanning
        case finished(DuplicateScanResults)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Hashing progress, 0...1, while `phase == .scanning`.
    private(set) var progress = 0.0
    /// When the finished result was computed (a live scan this session, or the
    /// cached run's timestamp), for the "Duplicates computed …" banner. Nil
    /// outside `.finished`.
    private(set) var computedAt: Date?
    /// The group the user drilled into, if any.
    private(set) var openGroup: DuplicateGroup?

    /// Minimum file size the finder uses; part of the result cache key.
    nonisolated static let minimumFileSize = DuplicateFinder.defaultMinimumFileSize

    /// Every confirmed duplicate, for the map-wide highlight while the
    /// results list is showing. Cached because the union set is derived
    /// per render otherwise.
    @ObservationIgnored private var allDuplicateIDs: Set<String> = []
    /// Which group each duplicate belongs to, so clicking a copy on the
    /// treemap can open its group.
    @ObservationIgnored private var groupIndexByNodeID: [String: Int] = [:]
    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// The snapshot the current phase belongs to; a scan finishing after
    /// the displayed tree changed must not publish stale results.
    @ObservationIgnored private var scannedSnapshotID: UUID?
    /// Drops stale cache-load completions after a snapshot change or a scan
    /// starting under them.
    @ObservationIgnored private var loadGeneration = 0

    init(coordinator: ScanCoordinator, snapshotCache: ScanSnapshotCache) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var results: DuplicateScanResults? {
        if case .finished(let results) = phase { return results }
        return nil
    }

    /// Scanning hashes file contents against the displayed tree, so it needs
    /// a complete snapshot and no scan already running. Cloud snapshots have
    /// no on-disk files to hash, so it never applies to them.
    var canScan: Bool {
        coordinator.snapshot?.isComplete == true
            && coordinator.snapshot?.target.kind != .cloud
            && !isScanning
    }

    /// Nodes lit on the treemap: the open group's copies, or every
    /// duplicate while the results list is showing.
    var highlightedNodeIDs: Set<String>? {
        if let openGroup { return Set(openGroup.nodeIDs) }
        guard case .finished = phase, !allDuplicateIDs.isEmpty else { return nil }
        return allDuplicateIDs
    }

    func startScan() {
        guard canScan, let snapshot = coordinator.snapshot else { return }
        let store = snapshot.treeStore
        let snapshotID = snapshot.id
        let target = snapshot.target
        scannedSnapshotID = snapshotID
        // A hashing run supersedes any in-flight cache load for this tab.
        loadGeneration += 1
        phase = .scanning
        progress = 0
        computedAt = nil
        openGroup = nil
        allDuplicateIDs = []
        groupIndexByNodeID = [:]
        scanTask?.cancel()
        // Built in method scope, not inside the detached work, so the
        // sendable hashing closure never touches the model directly.
        let reportProgress: @Sendable (DuplicateScanProgress) -> Void = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                guard self.scannedSnapshotID == snapshotID else { return }
                self.progress = max(self.progress, update.fractionCompleted)
            }
        }
        scanTask = Task { [weak self, snapshotCache] in
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try await DuplicateFinder.findDuplicates(
                        in: store,
                        minimumFileSize: Self.minimumFileSize,
                        onProgress: reportProgress
                    )
                }.value
                guard let self, !Task.isCancelled,
                      self.scannedSnapshotID == snapshotID else { return }
                let now = Date()
                self.computedAt = now
                self.apply(results: results)
                // Persist so the next open (this launch or after relaunch)
                // shows the result without re-hashing.
                await snapshotCache.saveDuplicateResults(
                    results,
                    computedAt: now,
                    forTargetID: target.id,
                    minimumFileSize: Self.minimumFileSize
                )
            } catch is CancellationError {
                // cancelScan / snapshotDidChange already reset the phase.
            } catch {
                guard let self, self.scannedSnapshotID == snapshotID else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Builds the map-wide highlight index (`allDuplicateIDs` plus the
    /// per-node group lookup) and publishes the results as `.finished`. Shared
    /// by the live-scan finish and the cache-load path so treemap highlighting
    /// and click-to-open-group behave identically whether results were just
    /// hashed or loaded from disk.
    private func apply(results: DuplicateScanResults) {
        allDuplicateIDs = Set(results.groups.flatMap(\.nodeIDs))
        var indexByNodeID: [String: Int] = [:]
        for (index, group) in results.groups.enumerated() {
            for nodeID in group.nodeIDs {
                indexByNodeID[nodeID] = index
            }
        }
        groupIndexByNodeID = indexByNodeID
        phase = .finished(results)
    }

    /// Fill an idle tab from a persisted result for the displayed snapshot, if
    /// one is cached; never hashes. Called from the pane when it is on screen,
    /// mirroring ChangesModel.loadIfNeeded — a hit enters `.finished`
    /// immediately, a miss leaves the idle prompt so the scan stays opt-in.
    func loadIfNeeded() {
        loadCachedResults(orScanIfMissing: false)
    }

    /// Load path with an opt-in fallback: tries the persisted result first and,
    /// only on a miss when `scanIfMissing` is set (the "find duplicates
    /// automatically" preference on a restored snapshot), starts a hashing
    /// scan. A running or finished scan already owns the phase, so this is a
    /// no-op unless the tab is idle and the snapshot has not been handled yet.
    func loadCachedResults(orScanIfMissing scanIfMissing: Bool) {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return }
        guard case .idle = phase, scannedSnapshotID != snapshot.id else { return }
        let snapshotID = snapshot.id
        let target = snapshot.target
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self, snapshotCache] in
            let cached = await snapshotCache.loadDuplicateResults(
                forTargetID: target.id,
                minimumFileSize: Self.minimumFileSize
            )
            guard let self, self.loadGeneration == generation,
                  self.coordinator.snapshot?.id == snapshotID,
                  case .idle = self.phase else { return }
            if let cached {
                self.scannedSnapshotID = snapshotID
                self.computedAt = cached.computedAt
                self.apply(results: cached.results)
            } else if scanIfMissing {
                self.startScan()
            }
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
        progress = 0
        computedAt = nil
    }

    func open(_ group: DuplicateGroup) {
        openGroup = group
    }

    /// Routes a selection (treemap or outline click) into the drill-in:
    /// selecting a duplicate opens its group — same as clicking the group
    /// row; selecting anything else while a group is open steps back out to
    /// the all-duplicates view, so clicking a dimmed cell is the intuitive
    /// "back". With no group open, non-duplicate selections change nothing.
    func handleSelection(of nodeID: String) {
        guard case .finished(let results) = phase else { return }
        if let index = groupIndexByNodeID[nodeID] {
            openGroup = results.groups[index]
        } else if openGroup != nil {
            openGroup = nil
        }
    }

    func closeGroup() {
        openGroup = nil
    }

    /// The displayed tree changed: results and the drill-in hold node IDs of
    /// the replaced tree, and a scan in flight is hashing files that may no
    /// longer exist.
    func snapshotDidChange() {
        scanTask?.cancel()
        scanTask = nil
        loadGeneration += 1
        scannedSnapshotID = nil
        phase = .idle
        progress = 0
        computedAt = nil
        openGroup = nil
        allDuplicateIDs = []
        groupIndexByNodeID = [:]
    }
}
