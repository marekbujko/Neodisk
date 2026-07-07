//
//  ScanConcurrencyPolicy.swift
//  Neodisk
//
//  Worker-pool sizing for the scan engine. Limits derive from hardware
//  (active cores) derated by the machine's power/thermal conditions.
//  Thermal state is re-sampled on a throttle during traversal (see
//  AdaptiveScanConcurrency) so a scan that starts cold and heat-soaks over
//  minutes sheds parallelism instead of running on the ceiling frozen at
//  scan setup.
//

import Foundation

/// A point-in-time sample of the power/thermal inputs that derate worker
/// ceilings.
nonisolated struct ScanThermalConditions: Sendable {
    let thermalState: ProcessInfo.ThermalState
    let isLowPowerModeEnabled: Bool

    nonisolated static func current() -> ScanThermalConditions {
        let processInfo = ProcessInfo.processInfo
        return ScanThermalConditions(
            thermalState: processInfo.thermalState,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled
        )
    }

    nonisolated static let nominal = ScanThermalConditions(
        thermalState: .nominal,
        isLowPowerModeEnabled: false
    )
}

nonisolated enum ScanConcurrencyPolicy {
    static let directoryClassificationParallelThreshold = 128
    // Shared budget for concurrent child metadata reads across traversal and classification workers.
    static let directoryMetadataWorkerBudgetMaximum = 16

    static func atomicSummaryWorkerLimit(for options: ScanOptions) -> Int {
        if let optionLimit = options.tuning.atomicSummaryWorkerLimit {
            return max(1, optionLimit)
        }

        if let environmentLimit = ProcessInfo.processInfo.environment["NEODISK_SCAN_ATOMIC_SUMMARY_WORKERS"]
            .flatMap(Int.init) {
            return max(1, environmentLimit)
        }

        return hardwareAwareWorkerLimit(minimum: 4, processorDivisor: 1, maximum: 8)
    }

    /// Explicit traversal-worker override from options or environment;
    /// nil means the limit is hardware-derived (and thermally adaptive).
    static func directoryTraversalWorkerOverride(for options: ScanOptions) -> Int? {
        if let optionLimit = options.tuning.directoryTraversalWorkerLimit {
            return max(1, optionLimit)
        }

        if let environmentLimit = ProcessInfo.processInfo.environment["NEODISK_SCAN_DIRECTORY_TRAVERSAL_WORKERS"]
            .flatMap(Int.init) {
            return max(1, environmentLimit)
        }

        return nil
    }

    static func directoryTraversalWorkerLimit(
        for options: ScanOptions,
        bulkEnumeration: Bool = false,
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        if let override = directoryTraversalWorkerOverride(for: options) {
            return override
        }

        // Bulk enumeration turns each directory into one fat, self-
        // contained work unit with no intra-directory sub-workers, so the
        // traversal pool is the only parallelism left — cores/2 measurably
        // starves it (~15.1s vs ~10.2s on a 470k-file fixture, 10 cores).
        if bulkEnumeration {
            return hardwareAwareWorkerLimit(minimum: 4, processorDivisor: 1, maximum: 8, conditions: conditions)
        }

        return hardwareAwareWorkerLimit(minimum: 2, processorDivisor: 2, maximum: 8, conditions: conditions)
    }

    /// Explicit classification-worker override from options or environment;
    /// nil means the limit is hardware-derived (and thermally adaptive).
    static func directoryClassificationWorkerOverride(for options: ScanOptions) -> Int? {
        if let optionLimit = options.tuning.directoryClassificationWorkerLimit {
            return max(1, optionLimit)
        }

        if let environmentLimit = ProcessInfo.processInfo.environment["NEODISK_SCAN_DIRECTORY_CLASSIFICATION_WORKERS"]
            .flatMap(Int.init) {
            return max(1, environmentLimit)
        }

        return nil
    }

    static func directoryClassificationWorkerLimit(
        for options: ScanOptions,
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        if let override = directoryClassificationWorkerOverride(for: options) {
            return override
        }

        return hardwareAwareWorkerLimit(minimum: 2, processorDivisor: 2, maximum: 8, conditions: conditions)
    }

    static func effectiveDirectoryClassificationWorkerLimit(
        traversalWorkerLimit: Int,
        classificationWorkerLimit: Int,
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        guard traversalWorkerLimit > 1 else {
            return classificationWorkerLimit
        }

        let sharedMetadataBudget = sharedMetadataWorkerBudget(conditions: conditions)
        let perDirectoryLimit = max(1, sharedMetadataBudget / max(1, traversalWorkerLimit))
        return min(classificationWorkerLimit, perDirectoryLimit)
    }

    private static func sharedMetadataWorkerBudget(conditions: ScanThermalConditions) -> Int {
        let activeProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var limit = min(
            max(4, activeProcessorCount * 2),
            directoryMetadataWorkerBudgetMaximum
        )

        if conditions.isLowPowerModeEnabled {
            limit = max(1, limit / 2)
        }

        switch conditions.thermalState {
        case .serious, .critical:
            limit = max(1, limit / 2)
        case .fair:
            limit = max(1, limit - 2)
        case .nominal:
            break
        @unknown default:
            break
        }

        return limit
    }

    private static func hardwareAwareWorkerLimit(
        minimum: Int,
        processorDivisor: Int,
        maximum: Int,
        conditions: ScanThermalConditions = .current()
    ) -> Int {
        let activeProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var limit = min(max(minimum, activeProcessorCount / max(1, processorDivisor)), maximum)

        if conditions.isLowPowerModeEnabled {
            limit = max(1, limit / 2)
        }

        switch conditions.thermalState {
        case .serious, .critical:
            limit = max(1, limit / 2)
        case .fair:
            limit = max(1, limit - 1)
        case .nominal:
            break
        @unknown default:
            break
        }

        return limit
    }
}

/// Live worker ceilings for one scan's traversal loop.
///
/// `refreshIfDue()` re-samples thermal conditions at most once per
/// `sampleInterval` (default 250 ms) and re-derives the traversal and
/// per-directory classification ceilings from the fresh sample. The
/// traversal dispatcher only launches new directory tasks while it is under
/// the ceiling, so a lowered ceiling sheds parallelism as in-flight tasks
/// drain — nothing is cancelled. Explicit option/environment overrides pin
/// their ceiling for the whole scan.
///
/// `thermalState` lags real DVFS throttling, so this is a coarse
/// mitigation aimed at multi-minute scans; short scans never leave the
/// initial sample.
///
/// Single-consumer by design: mutated only from the traversal loop.
nonisolated struct AdaptiveScanConcurrency {
    private let deriveTraversalLimit: @Sendable (ScanThermalConditions) -> Int
    private let deriveClassificationLimit: @Sendable (ScanThermalConditions) -> Int
    private let sampleConditions: @Sendable () -> ScanThermalConditions
    private let sampleInterval: Duration
    private var lastSampledAt: ContinuousClock.Instant
    private(set) var traversalWorkerLimit: Int
    /// Per-directory child-classification limit, already divided down by the
    /// shared metadata budget across traversal workers.
    private(set) var classificationWorkerLimit: Int

    init(
        options: ScanOptions,
        bulkEnumeration: Bool,
        sampleInterval: Duration = .milliseconds(250),
        sampleConditions: @escaping @Sendable () -> ScanThermalConditions = ScanThermalConditions.current
    ) {
        let traversalOverride = ScanConcurrencyPolicy.directoryTraversalWorkerOverride(for: options)
        let classificationOverride = ScanConcurrencyPolicy.directoryClassificationWorkerOverride(for: options)

        let deriveTraversalLimit: @Sendable (ScanThermalConditions) -> Int = { conditions in
            traversalOverride ?? ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
                for: options,
                bulkEnumeration: bulkEnumeration,
                conditions: conditions
            )
        }
        let deriveClassificationLimit: @Sendable (ScanThermalConditions) -> Int = { conditions in
            let base = classificationOverride ?? ScanConcurrencyPolicy.directoryClassificationWorkerLimit(
                for: options,
                conditions: conditions
            )
            return ScanConcurrencyPolicy.effectiveDirectoryClassificationWorkerLimit(
                traversalWorkerLimit: deriveTraversalLimit(conditions),
                classificationWorkerLimit: base,
                conditions: conditions
            )
        }

        let initialConditions = sampleConditions()
        self.deriveTraversalLimit = deriveTraversalLimit
        self.deriveClassificationLimit = deriveClassificationLimit
        self.sampleConditions = sampleConditions
        self.sampleInterval = sampleInterval
        self.lastSampledAt = ContinuousClock.now
        self.traversalWorkerLimit = deriveTraversalLimit(initialConditions)
        self.classificationWorkerLimit = deriveClassificationLimit(initialConditions)
    }

    mutating func refreshIfDue(now: ContinuousClock.Instant = .now) {
        guard now - lastSampledAt >= sampleInterval else { return }
        lastSampledAt = now
        let conditions = sampleConditions()
        traversalWorkerLimit = deriveTraversalLimit(conditions)
        classificationWorkerLimit = deriveClassificationLimit(conditions)
    }
}
