//
//  FreeSpaceModel.swift
//  Neodisk
//
//  The synthetic space next to the scanned tree: free space of the scanned
//  volume (or cloud quota remainder) and DaisyDisk-style hidden space. The
//  sunburst always renders both for volume scans; the treemap adds them only
//  behind the Settings toggle. Owned by NeodiskViewModel as `model.freeSpace`.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class FreeSpaceModel {
    /// Free space of the scanned volume, when the scan target is a volume.
    /// The sunburst always renders it; the treemap keeps the Settings toggle
    /// (default off) — see `treemapFreeSpaceBytes`.
    private(set) var freeSpaceBytes: Int64?
    /// DaisyDisk-style "hidden space" of the scanned volume: capacity that is
    /// neither free nor accounted for by the finished scan (purgeable space,
    /// local snapshots, files the scan could not read). Same gates as
    /// `freeSpaceBytes`, plus a complete snapshot — mid-scan the unscanned
    /// remainder is unknown, not hidden. Drawn as a synthetic cell/arc.
    private(set) var hiddenSpaceBytes: Int64?

    /// Settings backing the free-space cell; assigned by the view model's
    /// bindPreferences. Toggle reactivity rides on that binding's sink →
    /// update() reassigning the stored bytes, which fires observation.
    @ObservationIgnored var preferences: AppPreferences?

    @ObservationIgnored private let coordinator: ScanCoordinator
    /// The CloudScan integration, or nil in builds without the feature.
    @ObservationIgnored private let cloudScan: (any CloudScanIntegrating)?
    /// Last-known quota per cloud account, so the free-space cell renders
    /// immediately on reselect while a fresh figure is fetched.
    @ObservationIgnored private var cloudQuotaByTargetID: [String: (totalBytes: Int64?, usedBytes: Int64)] = [:]

    init(coordinator: ScanCoordinator, cloudScan: (any CloudScanIntegrating)?) {
        self.coordinator = coordinator
        self.cloudScan = cloudScan
    }

    /// The treemap's preference-gated view of the synthetic space: unlike
    /// the sunburst (which always shows free and hidden space for volume
    /// scans), the treemap adds them only when the Settings toggle is on.
    var treemapFreeSpaceBytes: Int64? {
        preferences?.showFreeSpace == true ? freeSpaceBytes : nil
    }
    var treemapHiddenSpaceBytes: Int64? {
        preferences?.showFreeSpace == true ? hiddenSpaceBytes : nil
    }

    func update() {
        if coordinator.selectedTarget?.kind == .cloud {
            updateCloudFreeSpace()
            return
        }
        guard let target = coordinator.selectedTarget,
              target.kind == .volume else {
            freeSpaceBytes = nil
            hiddenSpaceBytes = nil
            return
        }
        freeSpaceBytes = SystemIntegration.volumeAvailableCapacityForImportantUsage(for: target.url)
        // Hidden space needs a finished scan: a partial tree would misreport
        // the not-yet-visited remainder as hidden.
        let scannedBytes: Int64?
        if let snapshot = coordinator.snapshot, snapshot.isComplete {
            scannedBytes = snapshot.treeStore.root.allocatedSize
        } else {
            scannedBytes = nil
        }
        hiddenSpaceBytes = Self.hiddenSpaceBytes(
            totalCapacity: SystemIntegration.volumeTotalCapacity(for: target.url),
            availableCapacity: freeSpaceBytes,
            scannedBytes: scannedBytes
        )
    }

    /// Free space for a cloud account: quota capacity minus the account's
    /// whole-quota usage. Renders through the same gates as volume free space
    /// (sunburst always, treemap behind the Settings toggle). There is no
    /// remote analog of purgeable/hidden space; the scan's own synthetic
    /// "Unattributed" node covers trash and versions instead.
    private func updateCloudFreeSpace() {
        guard let target = coordinator.selectedTarget, target.kind == .cloud else { return }
        hiddenSpaceBytes = nil
        freeSpaceBytes = Self.cloudFreeSpaceBytes(quota: cloudQuotaByTargetID[target.id])
        guard let cloudScan else { return }
        Task { [weak self] in
            guard let quota = await cloudScan.quota(forTargetID: target.id),
                  let self,
                  self.coordinator.selectedTarget?.id == target.id else { return }
            self.cloudQuotaByTargetID[target.id] = quota
            self.freeSpaceBytes = Self.cloudFreeSpaceBytes(quota: quota)
        }
    }

    nonisolated static func cloudFreeSpaceBytes(
        quota: (totalBytes: Int64?, usedBytes: Int64)?
    ) -> Int64? {
        // Unknown or unlimited quota → no free-space cell.
        guard let quota, let total = quota.totalBytes else { return nil }
        let free = total - quota.usedBytes
        return free > 0 ? free : nil
    }

    /// DaisyDisk-style hidden space: total capacity minus available capacity
    /// minus what the scan accounted for, clamped at zero (nil when any input
    /// is missing or nothing remains). Uses the same available-capacity figure
    /// as the free-space cell, so scanned + free + hidden tiles the volume
    /// exactly instead of double-counting purgeable space.
    nonisolated static func hiddenSpaceBytes(
        totalCapacity: Int64?,
        availableCapacity: Int64?,
        scannedBytes: Int64?
    ) -> Int64? {
        guard let totalCapacity, let availableCapacity, let scannedBytes else { return nil }
        let hidden = totalCapacity - availableCapacity - scannedBytes
        return hidden > 0 ? hidden : nil
    }
}
