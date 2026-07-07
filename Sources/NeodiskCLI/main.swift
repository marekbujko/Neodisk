//
//  main.swift
//  diskscan
//
//  Command-line consumer of NeodiskKit: scans a directory or volume and
//  prints the largest entries (or a JSON tree). Exists both as a usable tool
//  and as the second consumer that keeps the core's public API honest.
//

import Foundation
import NeodiskKit

// MARK: - Argument parsing

struct CLIOptions {
    var path: String?
    var json = false
    /// Tree depth to print; 0 means unlimited.
    var depth = 1
    /// Entries shown per directory; 0 means unlimited.
    var top = 10
    var includeHidden = true
}

func printUsage(to handle: FileHandle) {
    let usage = """
    usage: diskscan <path> [--json] [--depth N] [--top N] [--no-hidden]

    Scans a directory tree and reports allocated sizes (hard links counted
    once, like du). Progress goes to stderr, results to stdout.

      --json       machine-readable summary + tree on stdout
      --depth N    directory levels to include (default 1, 0 = unlimited)
      --top N      largest entries kept per directory (default 10, 0 = all)
      --no-hidden  skip hidden files and directories (default: included)
      -h, --help   show this help
    """
    handle.write(Data((usage + "\n").utf8))
}

func parseOptions(_ arguments: [String]) -> CLIOptions? {
    var options = CLIOptions()
    var iterator = arguments.makeIterator()

    func numericValue(for flag: String) -> Int? {
        guard let raw = iterator.next(), let value = Int(raw), value >= 0 else {
            FileHandle.standardError.write(Data("error: \(flag) requires a non-negative integer\n".utf8))
            return nil
        }
        return value
    }

    while let argument = iterator.next() {
        switch argument {
        case "--json":
            options.json = true
        case "--depth":
            guard let value = numericValue(for: "--depth") else { return nil }
            options.depth = value
        case "--top":
            guard let value = numericValue(for: "--top") else { return nil }
            options.top = value
        case "--no-hidden":
            options.includeHidden = false
        case "-h", "--help":
            printUsage(to: FileHandle.standardOutput)
            exit(0)
        default:
            if argument.hasPrefix("-") || options.path != nil {
                FileHandle.standardError.write(Data("error: unexpected argument '\(argument)'\n".utf8))
                return nil
            }
            options.path = argument
        }
    }

    guard options.path != nil else {
        return nil
    }
    return options
}

// MARK: - Progress reporting (stderr)

struct ProgressReporter {
    private let isTTY = isatty(STDERR_FILENO) != 0
    private var lastPrintedWidth = 0
    private var lastPrint = ContinuousClock.now
    private var hasPrinted = false

    mutating func update(_ metrics: ScanMetrics) {
        guard isTTY else { return }
        let now = ContinuousClock.now
        guard !hasPrinted || lastPrint.duration(to: now) >= .milliseconds(100) else { return }
        lastPrint = now
        hasPrinted = true

        let line = "scanning… \(metrics.filesVisited) files, "
            + "\(metrics.directoriesVisited) folders, "
            + NeodiskFormatters.size(metrics.bytesDiscovered)
        let padding = String(repeating: " ", count: max(0, lastPrintedWidth - line.count))
        FileHandle.standardError.write(Data(("\r" + line + padding).utf8))
        lastPrintedWidth = line.count
    }

    mutating func finish() {
        guard isTTY, hasPrinted else { return }
        let blank = String(repeating: " ", count: lastPrintedWidth)
        FileHandle.standardError.write(Data(("\r" + blank + "\r").utf8))
        hasPrinted = false
    }
}

// MARK: - Text output

func printTextReport(snapshot: ScanSnapshot, options: CLIOptions) {
    let store = snapshot.treeStore
    let root = store.root
    let stats = snapshot.aggregateStats
    let duration = snapshot.finishedAt.map { $0.timeIntervalSince(snapshot.startedAt) }

    var header = "\(root.url.path) — \(NeodiskFormatters.size(stats.totalAllocatedSize))"
    header += " (\(stats.fileCount) files, \(stats.directoryCount) folders"
    if let duration {
        header += String(format: ", scanned in %.1fs)", duration)
    } else {
        header += ")"
    }
    print(header)

    printChildren(
        of: root.id,
        in: store,
        rootSize: stats.totalAllocatedSize,
        depth: 1,
        options: options,
        indent: "  "
    )
}

func printChildren(
    of nodeID: String,
    in store: FileTreeStore,
    rootSize: Int64,
    depth: Int,
    options: CLIOptions,
    indent: String
) {
    guard options.depth == 0 || depth <= options.depth else { return }

    let children = store.children(of: nodeID)
    guard !children.isEmpty else { return }

    let keptCount = options.top == 0 ? children.count : min(options.top, children.count)
    for child in children.prefix(keptCount) {
        let size = NeodiskFormatters.size(child.allocatedSize).padding(toLength: 10, withPad: " ", startingAt: 0)
        let share = NeodiskFormatters.percentage(part: child.allocatedSize, total: rootSize) ?? ""
        let marker = child.isDirectory ? "/" : ""
        print("\(indent)\(size) \(share.padding(toLength: 6, withPad: " ", startingAt: 0)) \(child.name)\(marker)")
        if child.isDirectory {
            printChildren(
                of: child.id,
                in: store,
                rootSize: rootSize,
                depth: depth + 1,
                options: options,
                indent: indent + "  "
            )
        }
    }

    let hidden = children.dropFirst(keptCount)
    if !hidden.isEmpty {
        let hiddenSize = hidden.reduce(Int64(0)) { $0.addingClamped($1.allocatedSize) }
        print("\(indent)…and \(hidden.count) more (\(NeodiskFormatters.size(hiddenSize)))")
    }
}

extension Int64 {
    func addingClamped(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}

// MARK: - JSON output

struct JSONNode: Encodable {
    let name: String
    let path: String
    let kind: String
    let allocatedSize: Int64
    let logicalSize: Int64
    let fileCount: Int?
    let children: [JSONNode]?
}

struct JSONSummary: Encodable {
    let target: String
    let totalAllocatedSize: Int64
    let totalLogicalSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let warningCount: Int
    let startedAt: Date
    let finishedAt: Date?
    let complete: Bool
}

struct JSONReport: Encodable {
    let summary: JSONSummary
    let root: JSONNode
}

func makeJSONNode(
    _ node: FileNodeRecord,
    in store: FileTreeStore,
    depth: Int,
    options: CLIOptions
) -> JSONNode {
    var children: [JSONNode]?
    if node.isDirectory, options.depth == 0 || depth < options.depth {
        let all = store.children(of: node.id)
        let kept = options.top == 0 ? all : Array(all.prefix(options.top))
        if !kept.isEmpty {
            children = kept.map { makeJSONNode($0, in: store, depth: depth + 1, options: options) }
        }
    }
    return JSONNode(
        name: node.name,
        path: node.url.path,
        kind: node.isDirectory ? "directory" : "file",
        allocatedSize: node.allocatedSize,
        logicalSize: node.logicalSize,
        fileCount: node.isDirectory ? node.descendantFileCount : nil,
        children: children
    )
}

func printJSONReport(snapshot: ScanSnapshot, options: CLIOptions) throws {
    let stats = snapshot.aggregateStats
    let report = JSONReport(
        summary: JSONSummary(
            target: snapshot.target.url.path,
            totalAllocatedSize: stats.totalAllocatedSize,
            totalLogicalSize: stats.totalLogicalSize,
            fileCount: stats.fileCount,
            directoryCount: stats.directoryCount,
            warningCount: snapshot.scanWarnings.count,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            complete: snapshot.isComplete
        ),
        root: makeJSONNode(snapshot.root, in: snapshot.treeStore, depth: 0, options: options)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

// MARK: - Entry point

guard let cliOptions = parseOptions(Array(CommandLine.arguments.dropFirst())) else {
    printUsage(to: FileHandle.standardError)
    exit(2)
}

let targetURL = URL(filePath: cliOptions.path!, directoryHint: .isDirectory)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue else {
    FileHandle.standardError.write(Data("error: not a directory: \(targetURL.path)\n".utf8))
    exit(1)
}

let target = ScanTarget(url: targetURL)
var scanOptions = ScanOptions()
scanOptions.includeHiddenFiles = cliOptions.includeHidden

let engine = ScanEngine()
var reporter = ProgressReporter()
var finishedSnapshot: ScanSnapshot?

do {
    for try await event in engine.scan(target: target, options: scanOptions) {
        switch event {
        case .progress(let metrics):
            reporter.update(metrics)
        case .warning, .partial:
            break
        case .finished(let snapshot):
            finishedSnapshot = snapshot
        }
    }
} catch {
    reporter.finish()
    FileHandle.standardError.write(Data("error: scan failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

reporter.finish()

guard let snapshot = finishedSnapshot else {
    FileHandle.standardError.write(Data("error: scan produced no result\n".utf8))
    exit(1)
}

if !snapshot.scanWarnings.isEmpty {
    FileHandle.standardError.write(
        Data("note: \(snapshot.scanWarnings.count) warning(s); some items were inaccessible\n".utf8)
    )
}

if cliOptions.json {
    try printJSONReport(snapshot: snapshot, options: cliOptions)
} else {
    printTextReport(snapshot: snapshot, options: cliOptions)
}
