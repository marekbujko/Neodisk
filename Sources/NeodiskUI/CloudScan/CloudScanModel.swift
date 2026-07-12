//
//  CloudScanModel.swift
//  Neodisk
//
//  The live CloudScan integration. Absent whenever CloudScanKit is excluded
//  from the build (nothing references the type there), so the whole file is
//  `#if canImport(CloudScanKit)` with no #else.
//

#if canImport(CloudScanKit)
import Foundation
import NeodiskKit
import CloudScanKit

/// Owns the CloudScanService and its providers, turns connected accounts into
/// sidebar targets, and adapts the service's `scan(target:)` into the
/// ScanEventStreaming the router expects.
@MainActor
final class CloudScanModel: CloudScanIntegrating {
    private let service: CloudScanService
    private let providers: [any CloudProvider]

    init(service: CloudScanService, providers: [any CloudProvider]) {
        self.service = service
        self.providers = providers
    }

    var accountTargets: [ScanTarget] {
        providers.flatMap { provider in
            let accounts = (try? provider.restoreAccounts()) ?? []
            return accounts.compactMap { account in
                CloudTargetID.target(
                    providerID: account.providerID,
                    accountID: account.accountID,
                    displayName: account.email
                )
            }
        }
    }

    func accountSubtitle(forTargetID targetID: String) -> String? {
        guard let parsed = CloudTargetID.parse(targetID),
              let provider = service.provider(forID: parsed.providerID) else {
            return nil
        }
        return provider.displayName
    }

    var scanService: any ScanEventStreaming {
        CloudScanServiceAdapter(service: service)
    }
}

/// Bridges CloudScanService.scan(target:) — which takes no ScanOptions — to
/// the ScanEventStreaming contract the coordinator and router speak.
private struct CloudScanServiceAdapter: ScanEventStreaming {
    let service: CloudScanService

    func scan(
        target: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        service.scan(target: target)
    }
}
#endif
