//
//  VizViewMode.swift
//  Neodisk
//
//  Which visualization fills the center pane: the cushion treemap or the
//  sunburst. Raw String so it can persist via AppPreferences.
//

enum VizViewMode: String, CaseIterable, Sendable {
    case treemap
    case sunburst
}
