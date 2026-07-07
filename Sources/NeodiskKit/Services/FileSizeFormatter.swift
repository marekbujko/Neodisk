//
//  FileSizeFormatter.swift
//  Neodisk
//

import Foundation

/// Formatting the core and CLI actually need: byte counts and percentages.
/// Display-only formatting (dates, durations) lives in the app
/// (DisplayFormatters).
public enum NeodiskFormatters {
    private static let formatterCache = FormatterCache()

    public static func size(_ bytes: Int64) -> String {
        formatterCache.size(bytes)
    }

    public static func percentage(part: Int64, total: Int64) -> String? {
        guard total > 0 else { return nil }
        return (Double(part) / Double(total))
            .formatted(.percent.precision(.fractionLength(1)))
    }
}

private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private let byteFormatter: ByteCountFormatter

    init() {
        let byteFormatter = ByteCountFormatter()
        byteFormatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        byteFormatter.countStyle = .file
        byteFormatter.includesActualByteCount = false
        byteFormatter.isAdaptive = true
        self.byteFormatter = byteFormatter
    }

    func size(_ bytes: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return byteFormatter.string(fromByteCount: bytes)
    }
}
