//
//  SunburstPane.swift
//  Neodisk
//
//  Model-facing entry point for the sunburst view: derives the chart's
//  inputs (root, color style, free space, layout identity) from the view
//  model and translates chart events into the same model actions the
//  treemap uses — hover to the status bar, single-click drill-in, center
//  click out, and the shared file-action context menu.
//

import AppKit
import SwiftUI
import TreemapKit
import NeodiskKit

struct SunburstPane: View {
    /// Rings drawn below the focused root (no settings knob in v1).
    static let depthLimit = 6

    let model: NeodiskViewModel

    var body: some View {
        if let store = model.store,
           let snapshot = model.coordinator.snapshot,
           let rootID = model.effectiveRootID,
           let rootNode = store.node(id: rootID) {
            let style = colorStyle
            let freeSpaceBytes = gatedFreeSpaceBytes
            SunburstChartView(
                rootNode: rootNode,
                parentNode: store.parent(of: rootID),
                treeStore: store,
                selectedNodeID: model.selectedNodeID,
                selectedAncestorIDs: selectedAncestorIDs(in: store),
                depthLimit: Self.depthLimit,
                layoutID: Self.layoutID(
                    snapshotID: snapshot.id,
                    rootID: rootID,
                    style: style,
                    freeSpaceBytes: freeSpaceBytes
                ),
                viewportResetID: "\(snapshot.id)|\(rootID)",
                style: style,
                freeSpaceBytes: freeSpaceBytes,
                onHoverSegment: { handleHover($0) },
                onClickSegment: { handleClick($0) },
                onNavigateToParent: { model.zoomOut() },
                contextMenu: { contextMenu(for: $0) }
            )
            // Switching back to the treemap must not leave the status bar
            // holding the last-hovered sunburst item.
            .onDisappear { clearHover() }
        } else {
            Color.clear
        }
    }

    // MARK: - Color style

    /// The active tab's coloring, mirroring `treemapColorMode` semantics:
    /// Largest gets Radix branch hues, Age the ramp with the same reference
    /// date as the treemap, everything else kind colors — with the active
    /// tab's highlight dimming baked in.
    private var colorStyle: SunburstColorStyle {
        var style = SunburstColorStyle(
            mode: .branch,
            catalog: model.kinds.catalog,
            highlight: model.treemapHighlight,
            palette: model.vizPalette
        )
        guard model.analysisTab != .largest else { return style }
        switch model.treemapColorMode {
        case .kind:
            style.mode = .kind
        case .age(let referenceDate):
            style.mode = .age(referenceDate: referenceDate)
        }
        return style
    }

    /// Free space belongs to the volume as a whole; hide it once the user
    /// drills into a subfolder (same gate as TreemapPane).
    private var gatedFreeSpaceBytes: Int64? {
        model.zoomRootID == nil ? model.freeSpaceBytes : nil
    }

    private func selectedAncestorIDs(in store: FileTreeStore) -> Set<String> {
        guard let selectedNodeID = model.selectedNodeID,
              store.node(id: selectedNodeID) != nil else { return [] }
        return Set(store.path(to: selectedNodeID).map(\.id))
    }

    /// One string capturing every layout input, so `.task(id:)` reloads on
    /// any change: snapshot, root, color mode, highlight, palette, free space.
    private static func layoutID(
        snapshotID: UUID,
        rootID: String,
        style: SunburstColorStyle,
        freeSpaceBytes: Int64?
    ) -> String {
        let modeKey: String
        switch style.mode {
        case .branch:
            modeKey = "branch"
        case .kind:
            modeKey = "kind"
        case .age(let referenceDate):
            modeKey = "age:\(referenceDate.timeIntervalSinceReferenceDate)"
        }

        let highlightKey: String
        switch style.highlight {
        case nil:
            highlightKey = "none"
        case .kind(let kindID):
            highlightKey = "kind:\(kindID)"
        case .ageBucket(let bucket):
            highlightKey = "age:\(bucket.rawValue)"
        case .nodes(let ids):
            // Duplicate groups can hold thousands of ids; a stable FNV-1a
            // digest keeps the layout id cheap while still changing whenever
            // the set does.
            highlightKey = "nodes:\(ids.count):\(stableDigest(of: ids))"
        }

        let paletteKey = style.palette == .colorblind ? "cb" : "std"
        return [
            snapshotID.uuidString,
            rootID,
            "\(depthLimit)",
            modeKey,
            highlightKey,
            paletteKey,
            style.catalog.buildID.uuidString,
            "\(freeSpaceBytes ?? 0)"
        ].joined(separator: "|")
    }

    private static func stableDigest(of ids: Set<String>) -> UInt64 {
        // Order-independent: combine per-id FNV-1a hashes commutatively.
        var combined: UInt64 = 0
        for id in ids {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in id.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            combined &+= hash
        }
        return combined
    }

    // MARK: - Interaction

    private func handleHover(_ segment: SunburstSegment?) {
        guard let segment else {
            clearHover()
            return
        }

        if segment.isFreeSpace {
            model.hoveredNodeID = nil
            model.hoveredAggregate = nil
            model.hoveredCellIsFreeSpace = true
            return
        }

        if segment.isAggregate {
            model.hoveredNodeID = segment.parentFolderID
            model.hoveredAggregate = TreemapCell.AggregateInfo(
                itemCount: segment.itemCount,
                totalSize: segment.totalSize
            )
            model.hoveredCellIsFreeSpace = false
            return
        }

        model.hoveredNodeID = segment.nodeID
        model.hoveredAggregate = nil
        model.hoveredCellIsFreeSpace = false
    }

    private func clearHover() {
        model.hoveredNodeID = nil
        model.hoveredAggregate = nil
        model.hoveredCellIsFreeSpace = false
    }

    private func handleClick(_ segment: SunburstSegment?) {
        guard let segment else {
            model.select(nil)
            return
        }

        if segment.isFreeSpace {
            model.select(nil)
            return
        }

        if segment.isAggregate {
            // Drilling into the containing folder gives the pooled items
            // more angle to spread out; when it is already the root (or
            // refuses), fall back to selecting the folder.
            guard let folderID = segment.parentFolderID else { return }
            if !model.drillIn(to: folderID) {
                model.select(folderID)
            }
            return
        }

        guard let nodeID = segment.nodeID else { return }
        if model.store?.node(id: nodeID)?.isDirectory == true {
            // The user's key ask: a single click on a folder segment drills
            // in. drillIn guards summarized/childless folders and manages
            // the selection; refusals degrade to a plain select.
            if !model.drillIn(to: nodeID) {
                model.select(nodeID)
            }
        } else {
            model.select(nodeID)
        }
    }

    /// Same actions as the treemap's context menu: Reveal in Finder / Open /
    /// Copy Path, plus Expand Contents for summarized folders.
    private func contextMenu(for segment: SunburstSegment) -> NSMenu? {
        guard let nodeID = segment.nodeID,
              let node = model.store?.node(id: nodeID),
              node.supportsFileActions else { return nil }

        let model = model
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SunburstMenuItem(title: NSLocalizedString("Reveal in Finder", comment: "Sunburst context menu")) { model.reveal(node) })
        menu.addItem(SunburstMenuItem(title: NSLocalizedString("Open", comment: "Sunburst context menu")) { model.open(node) })
        menu.addItem(SunburstMenuItem(title: NSLocalizedString("Copy Path", comment: "Sunburst context menu")) { model.copyPath(node) })

        if node.isAutoSummarized {
            menu.addItem(.separator())
            let item = SunburstMenuItem(title: NSLocalizedString("Expand Contents", comment: "Sunburst context menu")) { model.expandSummarizedNode(node) }
            item.isEnabled = model.canRefreshSubtree
            menu.addItem(item)
        }
        return menu
    }
}

/// NSMenuItem that runs a closure; NSMenu's target/action plumbing needs an
/// object to point at, and the item itself is the natural owner.
private final class SunburstMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("SunburstMenuItem does not support NSCoder")
    }

    @objc private func invoke() {
        handler()
    }
}
