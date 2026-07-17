//
//  ScanTiming.swift
//  Neodisk
//

import Darwin
import Foundation

/// Wall-clock phase timings for scans, printed to stderr as
/// `NEODISK_SCAN_TIMING phase=<name> ms=<value> [key=value …]` lines when
/// the `NEODISK_SCAN_TIMING=1` environment variable is set. The measurement
/// harness parses these lines, so the format is a contract — change it and
/// the harness together.
///
/// Phases are coarse (traversal, assembly, splice, encode…), never
/// per-entry, so enabling the instrumentation cannot skew what it measures.
nonisolated enum ScanTiming {
    static let isEnabled = ProcessInfo.processInfo.environment["NEODISK_SCAN_TIMING"] == "1"

    /// One-off context line (worker limits, derating events) — same prefix,
    /// no ms field, ignored by the stats parser.
    static func note(_ text: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data(("NEODISK_SCAN_TIMING note " + text + "\n").utf8))
    }

    static func record(_ phase: String, _ duration: Duration, detail: String = "") {
        guard isEnabled else { return }
        let milliseconds = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        var line = "NEODISK_SCAN_TIMING phase=\(phase) ms=\(String(format: "%.1f", milliseconds))"
        if !detail.isEmpty {
            line += " " + detail
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func measure<T>(
        _ phase: String,
        detail: String = "",
        _ body: () throws -> T
    ) rethrows -> T {
        guard isEnabled else { return try body() }
        let start = ContinuousClock.now
        let cpuStart = processCPUMilliseconds()
        defer {
            record(phase, start.duration(to: .now), detail: appendingCPUDelta(since: cpuStart, to: detail))
        }
        return try body()
    }

    static func measure<T>(
        _ phase: String,
        detail: String = "",
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard isEnabled else { return try await body() }
        let start = ContinuousClock.now
        let cpuStart = processCPUMilliseconds()
        defer {
            record(phase, start.duration(to: .now), detail: appendingCPUDelta(since: cpuStart, to: detail))
        }
        return try await body()
    }

    /// Process-wide CPU time (user, system) in milliseconds. Sampled only at
    /// phase boundaries, so it adds nothing to hot loops; concurrent phases
    /// would attribute each other's CPU, but the recorded scan phases run
    /// sequentially within a scan.
    private static func processCPUMilliseconds() -> (user: Double, system: Double) {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0) }
        func milliseconds(_ time: timeval) -> Double {
            Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
        }
        return (milliseconds(usage.ru_utime), milliseconds(usage.ru_stime))
    }

    private static func appendingCPUDelta(
        since start: (user: Double, system: Double),
        to detail: String
    ) -> String {
        let end = processCPUMilliseconds()
        let cpu = String(
            format: "cpuUserMs=%.1f cpuSysMs=%.1f",
            end.user - start.user,
            end.system - start.system
        )
        return detail.isEmpty ? cpu : detail + " " + cpu
    }
}
