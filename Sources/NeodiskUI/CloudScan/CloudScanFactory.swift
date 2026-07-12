//
//  CloudScanFactory.swift
//  Neodisk
//
//  Builds the CloudScan integration for the app, or returns nil when the
//  feature is unavailable (CloudScanKit excluded from the build) or unasked
//  for (no fixture; real providers come later). The app wires whatever this
//  returns into the view model and the routing scan service.
//

import Foundation
import NeodiskKit
#if canImport(CloudScanKit)
import CloudScanKit
#endif

enum CloudScanFactory {
#if canImport(CloudScanKit)
    @MainActor
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any CloudScanIntegrating)? {
        // M1 has no OAuth: the only account source is a JSON fixture named by
        // NEODISK_CLOUD_FIXTURE (the same hook the tests and screenshots use).
        // Google Drive arrives later.
        guard let fixturePath = environment["NEODISK_CLOUD_FIXTURE"] else { return nil }
        do {
            let provider = try FixtureCloudProvider(contentsOf: URL(filePath: fixturePath))
            let service = CloudScanService(providers: [provider])
            return CloudScanModel(service: service, providers: [provider])
        } catch {
            FileHandle.standardError.write(
                Data("Neodisk: could not load cloud fixture at \(fixturePath): \(error)\n".utf8)
            )
            return nil
        }
    }
#else
    @MainActor
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any CloudScanIntegrating)? {
        nil
    }
#endif
}
