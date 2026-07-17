//
//  HeadlessMode.swift
//  Neodisk
//
//  Dev/bench hook: NEODISK_HEADLESS=1 runs the real app off-screen for
//  end-to-end performance measurement (see INSTRUCTIONS/scripts/app-bench.sh).
//  It shares the offscreen/accessory machinery the NEODISK_UI_SNAPSHOT capture
//  path already uses — accessory activation (no Dock icon, never activates),
//  the window moved far offscreen and kept transparent, and the in-memory
//  CloudScan token store (a differently-signed binary reading the Keychain
//  puts an access prompt on screen) — but WITHOUT scheduling any capture. A
//  bench run that could draw on the user's screen is a bug; this is the one
//  switch both surfaces gate on.
//

import Foundation

enum HeadlessMode {
    /// True when the app must run entirely off-screen with no Dock presence
    /// and never steal focus: either a snapshot capture (NEODISK_UI_SNAPSHOT)
    /// or a felt-time bench run (NEODISK_HEADLESS=1).
    static var isOffscreen: Bool {
        ProcessInfo.processInfo.environment["NEODISK_UI_SNAPSHOT"] != nil
            || ProcessInfo.processInfo.environment["NEODISK_HEADLESS"] == "1"
    }
}
