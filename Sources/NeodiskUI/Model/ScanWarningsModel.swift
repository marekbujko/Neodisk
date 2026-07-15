//
//  ScanWarningsModel.swift
//  Neodisk
//
//  The floating warnings panel's state: which scan warnings are still
//  visible, which the user dismissed, and the Full Disk Access probe that
//  decides whether permission-denied warnings are worth showing at all.
//  Owned by NeodiskViewModel as `model.warnings`.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class ScanWarningsModel {
    /// Warnings the user closed in the floating panel. Reset when a new
    /// scan starts, so a rescan resurfaces still-current warnings.
    private(set) var dismissedWarningIDs: Set<ScanWarning.ID> = []

    /// Latest Full Disk Access probe result. With access granted, the
    /// permission-denied warnings that remain are dead ends the user cannot
    /// fix (other users' home folders, SIP-protected system paths), so the
    /// warning surfaces hide them. Refreshed on launch and app activation.
    var fullDiskAccessStatus: FullDiskAccessStatus = .unknown

    @ObservationIgnored private let coordinator: ScanCoordinator

    init(coordinator: ScanCoordinator) {
        self.coordinator = coordinator
    }

    func refreshFullDiskAccessStatus() async {
        fullDiskAccessStatus = await Task.detached(priority: .utility) {
            SystemIntegration.fullDiskAccessStatus()
        }.value
    }

    /// Scan warnings still visible in the floating panel (capped to keep the
    /// panel responsive on scans with thousands of skipped items).
    var visible: [ScanWarning] {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return [] }
        let hidePermissionDenied = fullDiskAccessStatus == .granted
        // Eager loop: a lazy filter whose predicate mutates state (the seen-ID
        // dedupe) violates Collection semantics and traps inside prefix(_:).
        var seenIDs = Set<ScanWarning.ID>()
        var visible: [ScanWarning] = []
        for warning in snapshot.scanWarnings {
            if hidePermissionDenied && warning.category == .permissionDenied { continue }
            // Warning identity is content-derived, so repeat warnings for the
            // same path collapse to one row.
            guard !dismissedWarningIDs.contains(warning.id),
                  seenIDs.insert(warning.id).inserted else { continue }
            visible.append(warning)
            if visible.count == 100 { break }
        }
        return visible
    }

    func dismiss(_ id: ScanWarning.ID) {
        dismissedWarningIDs.insert(id)
    }

    func dismissAll() {
        guard let snapshot = coordinator.snapshot else { return }
        dismissedWarningIDs.formUnion(snapshot.scanWarnings.map(\.id))
    }

    /// Clears the dismissals before a new scan or snapshot takes the screen.
    func reset() {
        dismissedWarningIDs = []
    }
}
