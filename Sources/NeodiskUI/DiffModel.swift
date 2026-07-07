//
//  DiffModel.swift
//  Neodisk
//
//  "Changes since last scan" state: the per-node size baseline decoded from
//  the previous snapshot, plus the toggle/loading choreography. Owned by
//  NeodiskViewModel as `model.diff`.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class DiffModel {
    /// Per-node sizes of the displayed target's previous scan. Non-nil
    /// means "changes since last scan" mode: the outline gains a Δ column
    /// and sorts by growth.
    private(set) var baseline: ScanSizeBaseline?
    /// True while the previous snapshot decodes for diff mode.
    private(set) var isLoading = false

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    /// Weak parent: diffing consults the model's snapshot-cache index
    /// (`cachedScanInfo`) and corrects it when the previous snapshot turns
    /// out to be gone.
    @ObservationIgnored weak var model: NeodiskViewModel?

    init(coordinator: ScanCoordinator, snapshotCache: ScanSnapshotCache) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
    }

    var isShowing: Bool {
        baseline != nil
    }

    /// Diffing needs a complete live scan on screen and a rotated previous
    /// snapshot on disk.
    var canShow: Bool {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete,
              snapshot.source.isPersistable else { return false }
        return model?.cachedScanInfo[snapshot.target.id]?.hasPreviousSnapshot == true
    }

    func toggle() {
        if baseline != nil {
            baseline = nil
            return
        }
        guard canShow, !isLoading,
              let target = coordinator.snapshot?.target else { return }
        load(for: target)
    }

    /// A baseline only makes sense against its own target.
    func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        if let baseline, snapshot?.target.id != baseline.targetID {
            self.baseline = nil
        }
    }

    /// Saving the displayed snapshot rotated its predecessor: a diff in
    /// progress now compares against the wrong generation, so rebase it on
    /// the freshly rotated previous snapshot.
    func rebaseAfterSnapshotRotation(for target: ScanTarget) {
        guard baseline?.targetID == target.id else { return }
        load(for: target)
    }

    private func load(for target: ScanTarget) {
        isLoading = true
        Task { [weak self, snapshotCache] in
            // Decode happens on the cache actor, the million-node baseline
            // build in a detached task; neither blocks the main actor.
            let previous = await snapshotCache.loadPreviousSnapshot(for: target)
            let baseline = await Task.detached(priority: .userInitiated) {
                previous.map(ScanSizeBaseline.init)
            }.value
            guard let self else { return }
            self.isLoading = false
            guard self.coordinator.snapshot?.target.id == target.id else { return }
            if let baseline {
                self.baseline = baseline
            } else {
                // The previous snapshot is gone (corrupt and deleted, or
                // cleared): reflect that so the toggle disables.
                self.baseline = nil
                self.model?.markPreviousSnapshotMissing(forTargetID: target.id)
            }
        }
    }
}
