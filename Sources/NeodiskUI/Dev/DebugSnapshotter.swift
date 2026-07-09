//
//  DebugSnapshotter.swift
//  Neodisk
//
//  Dev/testing hook: NEODISK_UI_SNAPSHOT=<out.png> waits for a scan, zooms
//  the map programmatically, and writes a capture of the whole window so
//  clipping and layer orientation can be verified headlessly. Lives outside
//  TreemapNSView so the shipping view class stays about rendering.
//

import AppKit

@MainActor
final class DebugSnapshotter {
    private var scheduled = false

    func scheduleIfRequested(for view: TreemapNSView) {
        guard view.window != nil, !scheduled,
              let path = ProcessInfo.processInfo.environment["NEODISK_UI_SNAPSHOT"] else {
            return
        }
        scheduled = true
        Self.log("scheduled windowNumber=\(view.window?.windowNumber ?? -1)")
        Task { @MainActor [weak view] in
            try? await Task.sleep(for: .seconds(6))
            guard let view else { return }
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            view.controller.magnify(by: 3, anchor: center)
            _ = view.controller.scroll(by: CGSize(width: -view.bounds.width, height: 0))
            try? await Task.sleep(for: .seconds(2))
            Self.writeWindowSnapshot(of: view, to: path)
        }
    }

    private static func writeWindowSnapshot(of view: NSView, to path: String) {
        guard let contentView = view.window?.contentView,
              let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            log("no content view to capture")
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            log("PNG encoding failed")
            return
        }
        do {
            try data.write(to: URL(filePath: path))
            log("wrote \(path)")
        } catch {
            log("\(error)")
        }
    }

    /// Unbuffered, so scripts driving the hook can read it while the app runs.
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("NEODISK_UI_SNAPSHOT: \(message)\n".utf8))
    }
}
