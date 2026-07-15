//
//  NeodiskViewModel+FileActions.swift
//  Neodisk
//
//  File actions for the selected node: Quick Look, Reveal in Finder, Open,
//  and Copy Path, plus the gates that disable them for cloud snapshots
//  (whose node paths are cloudscan:// identifiers, not filesystem paths).
//

import AppKit
import NeodiskKit

extension NeodiskViewModel {
    // MARK: - File actions

    /// False for a cloud snapshot: its nodes' paths are `cloudscan://`
    /// identifiers, not filesystem paths, so Reveal in Finder / Open / Copy
    /// Path / double-click reveal have nothing on disk to act on.
    var snapshotSupportsFileActions: Bool {
        coordinator.snapshot?.target.kind != .cloud
    }

    /// Whether the node's file actions (Reveal in Finder / Open / Copy Path)
    /// apply: the node must offer them and the displayed snapshot must be a
    /// filesystem scan.
    func supportsFileActions(_ node: FileNodeRecord) -> Bool {
        node.supportsFileActions && snapshotSupportsFileActions
    }

    /// Whether the selection's file actions apply — enablement for the
    /// Inspect menu's Open / Reveal in Finder / Copy Path items.
    var selectionSupportsFileActions: Bool {
        selectedNode.map(supportsFileActions) ?? false
    }

    /// Spacebar Quick Look shared by the treemap and sunburst: previews the
    /// selected node, so click-then-space works without ever focusing one of
    /// the sidebar lists. Beeps when nothing is selected.
    func quickLookSelection() {
        guard let node = selectedNode else {
            NSSound.beep()
            return
        }
        QuickLookPresenter.shared.togglePreview(for: node)
    }

    /// Return-key reveal shared by the treemap and sunburst. Beeps when the
    /// selection has no on-disk counterpart to show.
    func revealSelection() {
        guard let node = selectedNode, supportsFileActions(node) else {
            NSSound.beep()
            return
        }
        reveal(node)
    }

    /// Inspect > Open for the selection. Beeps when the selection has no
    /// on-disk counterpart (backstop; the menu item is disabled then).
    func openSelection() {
        guard let node = selectedNode, supportsFileActions(node) else {
            NSSound.beep()
            return
        }
        open(node)
    }

    /// Inspect > Copy Path for the selection, with the same beep backstop.
    func copyPathOfSelection() {
        guard let node = selectedNode, supportsFileActions(node) else {
            NSSound.beep()
            return
        }
        copyPath(node)
    }

    func reveal(_ node: FileNodeRecord) {
        SystemIntegration.reveal(node.url)
    }

    func open(_ node: FileNodeRecord) {
        do {
            try SystemIntegration.open(node.url)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func copyPath(_ node: FileNodeRecord) {
        do {
            try SystemIntegration.copyPath(node.url)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

}
