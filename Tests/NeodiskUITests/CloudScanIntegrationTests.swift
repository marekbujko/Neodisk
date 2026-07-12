import Testing
import Foundation
import NeodiskKit
@testable import NeodiskUI

/// The NeodiskUI-side CloudScan glue: the routing scan service and the view
/// model's connected-account plumbing. The cloud engine itself lives in
/// CloudScanKit and is tested there; these fakes stand in for it so the tests
/// stay independent of that (excludable) dependency.
@Suite struct CloudScanIntegrationTests {
    @MainActor
    @Test func testRoutesCloudTargetToCloudLeg() async throws {
        let local = RecordingStreamService()
        let cloud = RecordingStreamService()
        let service = RoutingScanService(localService: local, cloudService: cloud)

        try await drain(service.scan(target: makeCloudTarget(), options: ScanOptions()))

        #expect(cloud.recordedTargetIDs == [makeCloudTarget().id])
        #expect(local.recordedTargetIDs.isEmpty)
    }

    @MainActor
    @Test func testRoutesFolderTargetToLocalLeg() async throws {
        let local = RecordingStreamService()
        let cloud = RecordingStreamService()
        let service = RoutingScanService(localService: local, cloudService: cloud)
        let folder = makeTestTarget("/scan/local")

        try await drain(service.scan(target: folder, options: ScanOptions()))

        #expect(local.recordedTargetIDs == [folder.id])
        #expect(cloud.recordedTargetIDs.isEmpty)
    }

    @MainActor
    @Test func testCloudTargetWithoutCloudLegThrowsUnavailable() async throws {
        let local = RecordingStreamService()
        let service = RoutingScanService(localService: local, cloudService: nil)

        await #expect(throws: CloudScanUnavailableError.self) {
            try await drain(service.scan(target: makeCloudTarget(), options: ScanOptions()))
        }
        #expect(local.recordedTargetIDs.isEmpty)
    }

    @MainActor
    @Test func testViewModelExposesCloudAccountsInBuiltInLocations() throws {
        let account = makeCloudTarget()
        let cloudScan = FakeCloudScanIntegration(
            accountTargets: [account],
            subtitles: [account.id: "Fixture Drive"]
        )
        let environment = try IsolatedModelEnvironment()
        defer { environment.tearDown() }

        let model = environment.makeModel(cloudScan: cloudScan)

        #expect(model.cloudDriveAccounts.map(\.id) == [account.id])
        #expect(model.builtInLocations.contains { $0.id == account.id })
        #expect(model.cloudScan?.accountSubtitle(forTargetID: account.id) == "Fixture Drive")
    }
}

private func makeCloudTarget() -> ScanTarget {
    ScanTarget(
        id: "cloudscan://fixture/demo",
        url: URL(string: "cloudscan://fixture/demo")!,
        displayName: "demo@example.com",
        kind: .cloud
    )
}

/// Consumes a scan stream to completion, rethrowing whatever it throws.
private func drain(_ stream: AsyncThrowingStream<ScanProgressEvent, Error>) async throws {
    for try await _ in stream {}
}

/// A ScanEventStreaming that records which targets it was asked to scan and
/// finishes each stream immediately.
private final class RecordingStreamService: ScanEventStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var targetIDs: [String] = []

    var recordedTargetIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return targetIDs
    }

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        lock.lock()
        targetIDs.append(target.id)
        lock.unlock()
        return AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class FakeCloudScanIntegration: CloudScanIntegrating {
    let accountTargets: [ScanTarget]
    private let subtitles: [String: String]

    init(accountTargets: [ScanTarget], subtitles: [String: String]) {
        self.accountTargets = accountTargets
        self.subtitles = subtitles
    }

    var scanService: any ScanEventStreaming { RecordingStreamService() }

    func accountSubtitle(forTargetID targetID: String) -> String? {
        subtitles[targetID]
    }
}

/// A view model built against a throwaway snapshot cache and defaults suite,
/// so the init-time prune never touches the real cache.
private struct IsolatedModelEnvironment {
    private let cacheDirectory: URL
    private let cache: ScanSnapshotCache
    private let defaults: UserDefaults
    private let defaultsSuiteName: String
    private let sidebarFolderStore: SidebarFolderStore

    init() throws {
        cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "NeodiskCloudGlueTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        defaultsSuiteName = "NeodiskCloudGlueTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        sidebarFolderStore = SidebarFolderStore(defaults: defaults)
    }

    @MainActor
    func makeModel(cloudScan: any CloudScanIntegrating) -> NeodiskViewModel {
        NeodiskViewModel(
            snapshotCache: cache,
            sidebarFolderStore: sidebarFolderStore,
            cloudScan: cloudScan
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
    }
}
