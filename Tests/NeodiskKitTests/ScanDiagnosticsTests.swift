import Testing
import Foundation
@testable import NeodiskKit

#if DEBUG
@Suite struct ScanDiagnosticsTests {
    @Test func testSlowEventsRemainBoundedAndOrdered() {
        let diagnostics = ScanDiagnostics(environment: [
            "NEODISK_SCAN_DIAGNOSTICS_LIMIT": "3",
            "NEODISK_SCAN_DIAGNOSTICS_SLOW_MS": "0"
        ])

        for (operation, nanoseconds) in [
            ("op10", UInt64(10)),
            ("op30", UInt64(30)),
            ("op20", UInt64(20)),
            ("op40", UInt64(40)),
            ("op05", UInt64(5))
        ] {
            diagnostics.recordElapsed(
                operation: operation,
                url: URL(filePath: "/tmp/\(operation)"),
                nanoseconds: nanoseconds
            )
        }

        let report = diagnostics.makeReport(targetPath: "/tmp", elapsedSeconds: 0)
        let operations = slowEventLines(in: report).map(operationName)

        #expect(operations == ["op40", "op30", "op20"])
    }

    private func slowEventLines(in report: String) -> [String] {
        let lines = report.components(separatedBy: "\n")
        guard let headerIndex = lines.firstIndex(of: "NEODISK_SCAN_DIAGNOSTICS slow_events") else {
            return []
        }
        return Array(lines.dropFirst(headerIndex + 1))
    }

    private func operationName(from line: String) -> String {
        let fields = line.split(separator: " ")
        guard fields.count >= 2 else { return "" }
        return String(fields[1])
    }
}
#endif
