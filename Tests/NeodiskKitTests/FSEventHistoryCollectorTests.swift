import CoreServices
import Foundation
import Testing
@testable import NeodiskKit

/// Drives the replay collector directly with fabricated FSEvents callback
/// batches: per-path coalescing, the distinct-path budget, and the
/// `(since, through]` window filter, none of which can be pinned down
/// deterministically through a live fseventsd stream.
@Suite struct FSEventHistoryCollectorTests {
    private let mountPoint = "/Volumes/Test"

    private func makeCheckpoint(id: UInt64) -> FSEventsCheckpoint {
        FSEventsCheckpoint(volumeUUID: "test-uuid", eventID: id, capturedAt: Date(), osBuild: "test")
    }

    private func makeCollector(eventBudget: Int = 250_000) -> FSEventHistoryCollector {
        FSEventHistoryCollector(
            since: makeCheckpoint(id: 10),
            through: makeCheckpoint(id: 100),
            mountPoint: mountPoint,
            targetPath: mountPoint,
            firmlinkTranslator: FirmlinkPathTranslator(table: [:]),
            eventBudget: eventBudget
        )
    }

    private func deliver(
        _ events: [(path: String, flags: UInt32, id: UInt64)],
        to collector: FSEventHistoryCollector
    ) {
        let cStrings = events.map { strdup($0.path)! }
        defer { cStrings.forEach { free($0) } }
        let paths = cStrings.map { UnsafePointer($0) }
        let flags = events.map { FSEventStreamEventFlags($0.flags) }
        let ids = events.map { FSEventStreamEventId($0.id) }
        paths.withUnsafeBufferPointer { pathsBuffer in
            flags.withUnsafeBufferPointer { flagsBuffer in
                ids.withUnsafeBufferPointer { idsBuffer in
                    collector.receive(
                        eventCount: events.count,
                        relativePaths: pathsBuffer.baseAddress!,
                        rawFlags: flagsBuffer.baseAddress!,
                        eventIDs: idsBuffer.baseAddress!
                    )
                }
            }
        }
    }

    private let created = UInt32(kFSEventStreamEventFlagItemCreated)
    private let removed = UInt32(kFSEventStreamEventFlagItemRemoved)
    private let historyDone = UInt32(kFSEventStreamEventFlagHistoryDone)

    @Test func coalescesRepeatedPathsUnioningFlags() async throws {
        let collector = makeCollector()
        deliver([
            ("burst.txt", created, 11),
            ("burst.txt", 0, 12),
            ("burst.txt", removed, 13),
            ("other.txt", 0, 14),
            ("", historyDone, 0),
        ], to: collector)

        let history = try await collector.value()
        #expect(history.events.count == 2)
        let burst = try #require(history.events.first { $0.path == "\(mountPoint)/burst.txt" })
        #expect(burst.flags.contains(.itemCreated))
        #expect(burst.flags.contains(.itemRemoved))
        #expect(burst.eventID == 13)
        #expect(history.events.map(\.eventID) == [13, 14])
    }

    @Test func budgetCountsDistinctPathsNotRawEvents() async throws {
        let collector = makeCollector(eventBudget: 2)
        // 6 raw events but only 2 distinct paths: must fit the budget.
        deliver((0..<6).map { ("hot/cache.bin", created, UInt64(11 + $0 % 2)) }, to: collector)
        deliver([("hot/other.bin", created, 20), ("", historyDone, 0)], to: collector)

        let history = try await collector.value()
        #expect(history.events.count == 2)
    }

    @Test func distinctPathsBeyondBudgetFail() async throws {
        let collector = makeCollector(eventBudget: 2)
        deliver([
            ("a", created, 11),
            ("b", created, 12),
            ("c", created, 13),
        ], to: collector)

        await #expect(throws: FileSystemEventHistoryError.eventBudgetExceeded) {
            _ = try await collector.value()
        }
    }

    @Test func eventsOutsideTheWindowAreDropped() async throws {
        let collector = makeCollector()
        deliver([
            ("before.txt", created, 10),  // == since: excluded
            ("after.txt", created, 101),  // > through: excluded
            ("inside.txt", created, 100), // == through: included
            ("", historyDone, 0),
        ], to: collector)

        let history = try await collector.value()
        #expect(history.events.map(\.path) == ["\(mountPoint)/inside.txt"])
    }
}
