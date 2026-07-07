//
//  OutlinePane.swift
//  Neodisk
//
//  The left-hand outline: an expandable name/size tree over the scan,
//  flattened to visible rows so expansion can be driven programmatically
//  (treemap clicks auto-reveal their row).
//

import SwiftUI
import NeodiskKit

struct OutlinePane: View {
    let model: NeodiskViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if let results = model.search.results {
                OutlineSearchResultsList(model: model, results: results)
            } else {
                outlineTree
            }
        }
    }

    /// Entire-scan fuzzy search. Filtering never navigates or zooms — the
    /// treemap stays exactly where it is; only this pane's list changes.
    private var searchField: some View {
        @Bindable var search = model.search
        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Search entire scan", text: $search.text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($isSearchFocused)
                .onExitCommand {
                    model.search.clear()
                    isSearchFocused = false
                }
            if !model.search.text.isEmpty {
                Button {
                    model.search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: model.search.focusToken) { _, _ in
            isSearchFocused = true
        }
    }

    private var outlineTree: some View {
        let rows = model.visibleOutlineRows()
        let selection = Binding<String?>(
            get: { model.selectedNodeID },
            set: { model.selectedNodeID = $0 }
        )

        return ScrollViewReader { proxy in
            List(rows, selection: selection) { row in
                OutlineRowView(model: model, row: row)
                    .id(row.id)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        if row.node.supportsFileActions {
                            Button("Reveal in Finder") { model.reveal(row.node) }
                            Button("Open") { model.open(row.node) }
                            Button("Copy Path") { model.copyPath(row.node) }
                            if row.node.isAutoSummarized {
                                Divider()
                                Button("Expand Contents") {
                                    model.expandSummarizedNode(row.node)
                                }
                                .disabled(!model.canRefreshSubtree)
                            }
                        }
                    }
            }
            .environment(\.defaultMinListRowHeight, 20)
            .quickLookOnSpace(model: model)
            .onChange(of: model.selectedNodeID) { _, newValue in
                guard let newValue else { return }
                // Defer one runloop turn: scrolling synchronously here runs
                // inside the NSTableView selection delegate callback, which
                // AppKit flags as a reentrant table operation.
                Task { @MainActor in
                    proxy.scrollTo(newValue)
                }
            }
        }
    }
}

/// Flat, score-ranked results of the entire-scan search. Selecting a row is
/// a normal outline selection: treemap highlight via the existing sync, and
/// ancestors expand so clearing the search shows the node in context.
private struct OutlineSearchResultsList: View {
    let model: NeodiskViewModel
    let results: SearchModel.Results

    var body: some View {
        let selection = Binding<String?>(
            get: { model.selectedNodeID },
            set: { if let id = $0 { model.select(id) } }
        )

        if results.ids.isEmpty {
            Spacer()
            Text("No matches")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            List(results.ids, id: \.self, selection: selection) { nodeID in
                if let node = model.store?.node(id: nodeID) {
                    FileResultRow(node: node)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            if node.supportsFileActions {
                                Button("Reveal in Finder") { model.reveal(node) }
                                Button("Open") { model.open(node) }
                                Button("Copy Path") { model.copyPath(node) }
                            }
                        }
                }
            }
            .environment(\.defaultMinListRowHeight, 20)
            .quickLookOnSpace(model: model)

            if results.ids.count < results.totalMatches {
                Divider()
                Text("Top \(results.ids.count.formatted()) of \(results.totalMatches.formatted()) matches — refine to narrow")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
    }
}

private struct OutlineRowView: View {
    let model: NeodiskViewModel
    let row: NeodiskViewModel.OutlineRow

    var body: some View {
        HStack(spacing: 4) {
            Color.clear
                .frame(width: CGFloat(row.depth) * 14, height: 1)

            Group {
                if row.isExpandable {
                    Button {
                        model.toggleExpansion(row.node.id)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(
                                .degrees(model.expandedNodeIDs.contains(row.node.id) ? 90 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)

            Image(systemName: row.node.systemImageName)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 16)

            Text(row.node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if model.coordinator.expandingNodeID == row.node.id {
                // A subtree rescan/expansion is scanning this folder.
                ProgressView()
                    .controlSize(.mini)
            }

            if let baseline = model.diff.baseline {
                DeltaLabel(delta: baseline.sizeDelta(for: row.node))
            }

            Text(NeodiskFormatters.size(row.node.allocatedSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 12))
    }

    private var iconColor: Color {
        if row.node.isDirectory {
            return .secondary
        }
        return model.kinds.catalog.color(for: row.node)
    }
}

/// Growth since the baseline scan: "+1.2 GB" in red, "−340 MB" in green,
/// a quiet dot for unchanged nodes.
private struct DeltaLabel: View {
    let delta: Int64

    var body: some View {
        Group {
            if delta == 0 {
                Text("·")
                    .foregroundStyle(.tertiary)
            } else if delta > 0 {
                Text("+\(NeodiskFormatters.size(delta))")
                    .foregroundStyle(.red)
            } else {
                Text("−\(NeodiskFormatters.size(-delta))")
                    .foregroundStyle(.green)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}
