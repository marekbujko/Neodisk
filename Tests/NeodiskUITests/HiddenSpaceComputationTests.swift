//
//  HiddenSpaceComputationTests.swift
//  Neodisk
//
//  The DaisyDisk-style hidden-space figure: volume capacity minus available
//  capacity minus what a finished scan accounted for. These tests pin the
//  arithmetic and its gating — any missing input, or nothing remaining,
//  yields no hidden space at all.
//

import Foundation
import Testing
@testable import NeodiskUI

@Suite struct HiddenSpaceComputationTests {
    @Test func hiddenSpaceIsCapacityMinusAvailableMinusScanned() {
        #expect(FreeSpaceModel.hiddenSpaceBytes(
            totalCapacity: 1_000, availableCapacity: 300, scannedBytes: 500
        ) == 200)
    }

    @Test func missingInputsYieldNoHiddenSpace() {
        #expect(FreeSpaceModel.hiddenSpaceBytes(
            totalCapacity: nil, availableCapacity: 300, scannedBytes: 500
        ) == nil)
        #expect(FreeSpaceModel.hiddenSpaceBytes(
            totalCapacity: 1_000, availableCapacity: nil, scannedBytes: 500
        ) == nil)
        // No scanned total (scan incomplete or absent): the unaccounted
        // remainder is unknown, not hidden.
        #expect(FreeSpaceModel.hiddenSpaceBytes(
            totalCapacity: 1_000, availableCapacity: 300, scannedBytes: nil
        ) == nil)
    }

    @Test func nonPositiveRemaindersClampToNothing() {
        // Exactly accounted for.
        #expect(FreeSpaceModel.hiddenSpaceBytes(
            totalCapacity: 1_000, availableCapacity: 300, scannedBytes: 700
        ) == nil)
        // Over-accounted (hard links, purgeable churn between the two
        // capacity reads): never a negative synthetic block.
        #expect(FreeSpaceModel.hiddenSpaceBytes(
            totalCapacity: 1_000, availableCapacity: 300, scannedBytes: 900
        ) == nil)
    }
}
