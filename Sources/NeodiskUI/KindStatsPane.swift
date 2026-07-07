//
//  KindStatsPane.swift
//  Neodisk
//
//  Disk Inventory X-style file kind statistics: one row per kind with its
//  treemap color, total size, and file count, largest first.
//

import SwiftUI
import NeodiskKit

struct KindStatsPane: View {
    let model: NeodiskViewModel

    var body: some View {
        if model.kinds.fileList != nil || model.kinds.isFileListLoading {
            KindFileListView(model: model)
        } else {
            kindStatsList
        }
    }

    private var kindStatsList: some View {
        @Bindable var kinds = model.kinds
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("File Kinds")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $kinds.displayMode) {
                    ForEach(FileKindDisplayMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider()

            if model.kinds.catalog.stats.isEmpty || model.kinds.catalog.mode != model.kinds.displayMode {
                // Either nothing built yet, or the user just switched modes
                // and the catalog for the new mode is still building — don't
                // show the stale list.
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.kinds.catalog.stats) { stat in
                    KindStatRow(stat: stat, totalSize: totalSize)
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.kinds.openFileList(for: stat)
                        }
                        .help("Show every file of this kind")
                }
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
    }

    private var totalSize: Int64 {
        model.coordinator.snapshot?.aggregateStats.totalAllocatedSize ?? 0
    }
}

/// Drill-in from a kind row: every file of that kind, largest first,
/// searchable. Read-only — clicking a row selects the file in the outline
/// and treemap.
private struct KindFileListView: View {
    let model: NeodiskViewModel

    var body: some View {
        @Bindable var kinds = model.kinds
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    model.kinds.closeFileList()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to file kinds")

                if let list = model.kinds.fileList {
                    let rgb = model.kinds.catalog.rgb(forKindID: list.kind.id)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)))
                        .frame(width: 12, height: 12)
                    Text(LocalizedStringKey(list.kind.displayName))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Loading…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Filter by name", text: $kinds.fileListFilterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()

            if model.kinds.isFileListLoading {
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                let selection = Binding<String?>(
                    get: { model.selectedNodeID },
                    set: { if let id = $0 { model.select(id) } }
                )
                List(model.kinds.fileListVisibleIDs, id: \.self, selection: selection) { nodeID in
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

                if model.kinds.fileListVisibleIDs.count < model.kinds.fileListTotalMatches {
                    Divider()
                    Text(footerText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private var footerText: String {
        let shown = model.kinds.fileListVisibleIDs.count.formatted()
        let total = model.kinds.fileListTotalMatches.formatted()
        let format = model.kinds.fileListFilterText.trimmingCharacters(in: .whitespaces).isEmpty
            ? NSLocalizedString("Largest %@ of %@ — search to narrow", comment: "File list footer, no filter")
            : NSLocalizedString("Top %@ of %@ matches — refine to narrow", comment: "File list footer, filtered")
        return String(format: format, shown, total)
    }
}

private struct KindStatRow: View {
    let stat: FileKindStat
    let totalSize: Int64

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(stat.color)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(stat.kind.displayName))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(stat.fileCount.formatted()) files")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(NeodiskFormatters.size(stat.totalAllocatedSize))
                    .monospacedDigit()
                if let percent = NeodiskFormatters.percentage(
                    part: stat.totalAllocatedSize, total: totalSize
                ) {
                    Text(percent)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: 12))
    }
}
