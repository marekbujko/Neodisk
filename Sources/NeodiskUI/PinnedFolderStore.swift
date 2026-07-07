//
//  PinnedFolderStore.swift
//  Neodisk
//
//  Folders the user added via "Add Folder…", persisted across launches.
//

import Foundation
import NeodiskKit

struct PinnedFolderStore {
    private static let defaultsKey = "pinnedFolderPaths"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [ScanTarget] {
        let paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        return paths.map { path in
            ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory))
        }
    }

    func add(_ target: ScanTarget) {
        var paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        guard !paths.contains(target.id) else { return }
        paths.append(target.id)
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    func remove(_ target: ScanTarget) {
        var paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        paths.removeAll { $0 == target.id }
        defaults.set(paths, forKey: Self.defaultsKey)
    }
}
