//
//  NeodiskViewModel.swift
//  Neodisk
//
//  Central UI state: scan lifecycle, selection, zoom, kind statistics, and
//  the rendered treemap.
//

import SunburstCore
import AppKit
import Combine
import Observation
import SwiftUI
import TreemapKit
import NeodiskKit

@MainActor
@Observable
final class NeodiskViewModel {
    let coordinator: ScanCoordinator

    var selectedNodeID: String? {
        didSet {
            guard selectedNodeID != oldValue else { return }
            // Any selection — from the treemap, outline, sidebar lists, or
            // search — keeps itself on screen: if it lands outside a
            // drilled-in map, widen the root out to reveal it. Done here, not
            // in select(), because the outline sets selectedNodeID directly.
            if let selectedNodeID { widenRootToShow(selectedNodeID) }
            // Live-update an open Quick Look panel as the selection moves
            // (arrow-keying through the outline). No-op when it's closed.
            QuickLookPresenter.shared.selectionDidChange(to: selectedNode)
        }
    }
    var hoveredNodeID: String?
    /// Set while the cursor is over a merged "smaller items" treemap cell;
    /// `hoveredNodeID` then points at the containing folder.
    var hoveredAggregate: TreemapCell.AggregateInfo?
    /// True while the cursor is over the synthetic free-space cell (whose
    /// node exists in no tree store).
    var hoveredCellIsFreeSpace = false
    /// True while the cursor is over the synthetic hidden-space cell (whose
    /// node exists in no tree store).
    var hoveredCellIsHiddenSpace = false
    /// Node the treemap is currently zoomed into; nil means the snapshot root.
    var zoomRootID: String?
    /// Folders whose "smaller items" cell the user clicked open — their
    /// children render individually even when tiny.
    var expandedAggregateIDs: Set<String> = []
    var showKindStats = true {
        didSet { syncDiffVisibility() }
    }
    /// Which statistics-panel tab is active. Also decides what treemap color
    /// means (Age colors by modification date; the others keep kind colors)
    /// and which drill-in highlight reaches the map — see treemapColorMode /
    /// treemapHighlight. Deliberately not reset per scan: the chosen lens
    /// carries across locations. Starts on Largest — the first tab, and the
    /// first question a disk tool gets asked.
    var analysisTab: AnalysisTab = .largest {
        didSet { syncDiffVisibility() }
    }
    /// Locations sidebar visibility; lives here so the View menu can toggle
    /// it. Always starts visible.
    var sidebarVisibility = NavigationSplitViewVisibility.all
    /// Which visualization the center pane shows (treemap or sunburst).
    /// Preference mirroring happens where the toolbar switcher binds.
    /// The diff stays armed across the switch: sunburst has no Δ column to
    /// render, but switching back to the treemap must not lose the mode.
    var vizViewMode: VizViewMode = .treemap

    // MARK: Kind statistics

    /// Kind catalog, display mode, and drill-in file list; see
    /// KindStatsModel.
    let kinds: KindStatsModel

    // MARK: Largest files

    /// The whole scan's biggest files, flat and size-descending; see
    /// LargestFilesModel.
    let largest: LargestFilesModel

    // MARK: Age statistics

    /// Modification-age buckets and drill-in file list; see AgeStatsModel.
    let ages: AgeStatsModel

    // MARK: Duplicates

    /// On-demand duplicate-content scan and results; see DuplicatesModel.
    let duplicates: DuplicatesModel

    // MARK: Changes list

    /// Added/deleted/renamed/grown/shrunk entries against the previous
    /// scan, for the statistics panel's Changes tab; see ChangesModel.
    let changes: ChangesModel

    // MARK: Entire-scan search

    /// Outline "search entire scan" feature state; see SearchModel.
    let search: SearchModel

    var expandedNodeIDs: Set<String> = []
    var actionErrorMessage: String?
    /// True after the user stops a scan mid-flight while partial results are
    /// on screen: the scan strip stays visible offering Resume.
    var scanWasStopped = false
    /// Shows the first-launch welcome sheet (also reachable from Settings).
    var showWelcomeSheet = false

    // MARK: Scan warnings

    /// Floating-panel warning visibility, dismissals, and the Full Disk
    /// Access probe; see ScanWarningsModel.
    let warnings: ScanWarningsModel
    /// The sidebar's Folders section: seeded with the common folders on
    /// first launch, extended by Add Folder, every entry removable.
    var sidebarFolders: [ScanTarget] = []
    /// Mounted volumes shown in the sidebar's Volumes section.
    let volumeLocations = SystemIntegration.volumeTargets()
    /// Locally-synced cloud storage folders (iCloud Drive, File Provider
    /// roots), shown in the sidebar's own "Local Cloud Files" section.
    let cloudLocations = SystemIntegration.cloudTargets()
    /// Connected remote cloud-drive accounts and their connect/sign-out
    /// flows; see CloudAccountsModel.
    let cloudAccounts: CloudAccountsModel
    /// The fixed sidebar locations: volumes, local cloud folders, and remote
    /// cloud-drive accounts. Unlike the Folders section these can never be
    /// removed. Feeding cloud accounts through here joins them into sidebar
    /// selection (`allTargets`), dedup, and the snapshot-cache keep-list.
    var builtInLocations: [ScanTarget] { volumeLocations + cloudLocations + cloudAccounts.accounts }
    /// What the snapshot cache holds per target path: which locations open
    /// instantly from cache, the sidebar's "Scanned … ago" subtitles, and
    /// how long the last scan took (whether a rescan should auto-start).
    private(set) var cachedScanInfo: [String: CachedScanInfo] = [:]
    /// Shown while a cached snapshot stands in for a skipped auto-rescan:
    /// the floating notice offering the rescan the app didn't start.
    var snapshotNotice: SnapshotNotice?

    /// Under the smart auto-rescan policy: rescans that finished faster than
    /// this last time keep the original click-to-rescan behavior; slower ones
    /// display their snapshot and leave rescanning to the user (via the
    /// notice or the toolbar).
    static let autoRescanMaxLastScanDuration: TimeInterval = 15

    struct SnapshotNotice: Equatable {
        let targetID: String
        let scanDate: Date
        let lastScanDuration: TimeInterval?
    }

    /// "Changes since last scan" baseline; see DiffModel. Visibility is
    /// driven by the Changes tab (`wantsDiffVisible`), not a toolbar toggle.
    let diff: DiffModel

    /// The Changes tab owns the diff display: while it is the active tab of
    /// a visible statistics panel, the outline shows its Δ column (and the
    /// tab its list). Hiding the panel or switching tabs turns both off —
    /// the same contract the sunburst uses for tab-driven coloring.
    var wantsDiffVisible: Bool {
        showKindStats && analysisTab == .changes
    }

    private func syncDiffVisibility() {
        diff.setShowing(wantsDiffVisible)
    }
    // MARK: Free & hidden space

    /// Volume free space, hidden space, and cloud quota remainders; see
    /// FreeSpaceModel.
    let freeSpace: FreeSpaceModel

    /// Mirror of the persisted cloud-only toggle, synced by bindPreferences
    /// so observation fires when it flips (same pattern as free space).
    var showCloudOnlyFilesPreferred = true
    /// Whether the displayed snapshot contains any cloud-only (dataless)
    /// bytes — gates the toolbar toggle, which is otherwise a no-op.
    var snapshotHasCloudItems: Bool {
        guard let store = coordinator.snapshot?.treeStore else { return false }
        return (store.node(id: store.rootID)?.cloudOnlyLogicalSize ?? 0) > 0
    }
    /// The effective display flag both visualizations weight by:
    /// preference on, and the snapshot actually has cloud-only bytes.
    var showsCloudOnlyFiles: Bool {
        showCloudOnlyFilesPreferred && snapshotHasCloudItems
    }

    /// Settings backing scan options and the free-space cell; assigned once
    /// by the app at launch.
    var preferences: AppPreferences? {
        didSet { bindPreferences() }
    }

    /// One search index per displayed snapshot, shared by the outline
    /// search and the kind drill-in list.
    @ObservationIgnored private let searchIndexService = SearchIndexService()
    @ObservationIgnored private let sidebarFolderStore: SidebarFolderStore
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    /// False until the launch prune has filled `cachedScanInfo`; before that,
    /// scans probe the cache optimistically instead of trusting the index.
    @ObservationIgnored private var hasIndexedSnapshotCache = false
    @ObservationIgnored private var preferencesCancellable: AnyCancellable?

    init(
        coordinator: ScanCoordinator = ScanCoordinator(),
        snapshotCache: ScanSnapshotCache = ScanSnapshotCache(),
        sidebarFolderStore: SidebarFolderStore = SidebarFolderStore(),
        cloudScan: (any CloudScanIntegrating)? = nil
    ) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
        self.sidebarFolderStore = sidebarFolderStore
        self.warnings = ScanWarningsModel(coordinator: coordinator)
        self.freeSpace = FreeSpaceModel(coordinator: coordinator, cloudScan: cloudScan)
        // Seeds the connected cloud accounts before the keep-list below is
        // computed, so their persisted snapshots survive the launch prune
        // (builtInLocations folds cloudAccounts.accounts in).
        self.cloudAccounts = CloudAccountsModel(
            coordinator: coordinator,
            snapshotCache: snapshotCache,
            integration: cloudScan
        )
        self.search = SearchModel(coordinator: coordinator, indexService: searchIndexService)
        self.kinds = KindStatsModel(coordinator: coordinator, indexService: searchIndexService)
        self.largest = LargestFilesModel(coordinator: coordinator, indexService: searchIndexService)
        self.ages = AgeStatsModel(coordinator: coordinator, indexService: searchIndexService)
        self.duplicates = DuplicatesModel(coordinator: coordinator, snapshotCache: snapshotCache)
        self.diff = DiffModel(coordinator: coordinator, snapshotCache: snapshotCache)
        self.changes = ChangesModel(coordinator: coordinator, snapshotCache: snapshotCache)
        sidebarFolders = sidebarFolderStore.load()
        diff.model = self
        changes.model = self
        cloudAccounts.model = self

        // The coordinator is @Observable, so views track its properties
        // (phase, snapshot, …) directly; the model only needs the snapshot
        // change hook for its own bookkeeping.
        coordinator.onSnapshotChange = { [weak self] snapshot in
            self?.snapshotDidChange(snapshot)
        }

        coordinator.onScanFinished = { [weak self] snapshot in
            guard let self else { return }
            self.persistCompletedSnapshot(snapshot)
            // Opt-in convenience: kick off the duplicate content scan the
            // moment a scan lands, so the Duplicates tab is ready (or at
            // least underway) by the time the user opens it.
            if self.preferences?.autoScanDuplicates == true {
                self.duplicates.startScan()
            }
        }

        // Drop cache entries for locations no longer in the sidebar and
        // learn which targets can open instantly from cache.
        let validTargetIDs = Set((builtInLocations + sidebarFolders).map(\.id))
        Task { [weak self, snapshotCache] in
            let index = await snapshotCache.pruneAndIndex(keepingTargetIDs: validTargetIDs)
            // A scan finishing during the prune has the newer entry — keep it.
            self?.cachedScanInfo.merge(index) { current, _ in current }
            self?.hasIndexedSnapshotCache = true
        }
    }

    var store: FileTreeStore? {
        coordinator.snapshot?.treeStore
    }

    var effectiveRootID: String? {
        guard let store else { return nil }
        if let zoomRootID, store.node(id: zoomRootID) != nil {
            return zoomRootID
        }
        return store.root.id
    }

    var selectedNode: FileNodeRecord? {
        store?.node(id: selectedNodeID)
    }

    var hoveredNode: FileNodeRecord? {
        store?.node(id: hoveredNodeID)
    }

    // MARK: - Treemap coloring

    /// What treemap color means, driven by the statistics-panel tab: the Age
    /// tab colors by modification date (bucketed against the scan date, so
    /// the map matches the tab's legend), every other tab colors by kind.
    /// The mode survives hiding the panel — the panel is the legend, not the
    /// owner of the state.
    var treemapColorMode: TreemapColorMode {
        guard analysisTab == .age else { return .kind }
        let referenceDate = ages.catalog.stats.isEmpty
            ? coordinator.snapshot.map { $0.finishedAt ?? $0.startedAt }
            : ages.catalog.referenceDate
        guard let referenceDate else { return .kind }
        return .age(referenceDate: referenceDate)
    }

    /// The active tab's drill-in highlight, if any — only the visible tab's
    /// selection reaches the map, so switching tabs never leaves a stale dim.
    var treemapHighlight: TreemapHighlight? {
        switch analysisTab {
        case .kinds:
            return kinds.highlightedKindID.map { .kind($0) }
        case .largest:
            // No dim: the plain selection ring already ties a clicked row to
            // its cell, and the map keeps kind colors.
            return nil
        case .age:
            return ages.highlightedBucket.map { .ageBucket($0) }
        case .duplicates:
            return duplicates.highlightedNodeIDs.map { .nodes($0) }
        case .changes:
            // No dim, like Largest: the plain selection ring already ties a
            // clicked change to its cell, and the map keeps kind colors.
            return nil
        }
    }

    /// The active visualization palette, driven by the colorblind Settings
    /// toggle. Kind colors are baked into the catalog (see KindStatsModel);
    /// age and status-bar swatch colors read this live.
    var vizPalette: VizPalette {
        preferences?.useColorblindPalette == true ? .colorblind : .standard
    }

    /// The swatch color a node renders with on the map right now — the
    /// status bar's swatch must agree with the active view and color mode.
    /// On the sunburst's Largest tab — or whenever the statistics panel is
    /// hidden, which reverts the sunburst to its default coloring — that is
    /// the Radix branch hue; every other combination keeps the treemap's
    /// kind/age semantics.
    func displayColor(for node: FileNodeRecord) -> Color {
        if vizViewMode == .sunburst, analysisTab == .largest || !showKindStats, let store {
            return SunburstColorResolver.branchColor(
                forNodeID: node.id,
                in: store,
                effectiveRootID: effectiveRootID ?? store.root.id,
                palette: vizPalette
            )
        }
        if case .age(let referenceDate) = treemapColorMode {
            guard FileKindClassifier.isLeafLike(node) else {
                let rgb = FileKindCatalog.directoryRGB
                return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
            }
            return vizPalette.ageColor(AgeBucket.bucket(for: node.lastModified, reference: referenceDate))
        }
        return kinds.catalog.color(for: node)
    }

    // MARK: - Scanning

    /// Volume totals are wrong without hidden system metadata
    /// (.Spotlight-V100, .fseventsd, .Trashes, …), so volume scans always
    /// include hidden files regardless of the preference.
    private func scanOptions(for target: ScanTarget) -> ScanOptions {
        var options = preferences?.scanOptions ?? ScanOptions()
        if target.kind == .volume {
            options.includeHiddenFiles = true
        }
        return options
    }

    func startScan(_ target: ScanTarget, forcesRescan: Bool = false) {
        let options = scanOptions(for: target)
        let displaysTargetAlready = coordinator.snapshot?.isComplete == true
            && coordinator.snapshot?.target.id == target.id
        if displaysTargetAlready {
            // Re-selecting a snapshot whose rescan the app deliberately
            // skipped must not start that rescan by accident — the notice
            // and the toolbar button are the explicit ways in.
            if !forcesRescan, snapshotNotice?.targetID == target.id {
                return
            }
            // Rescan of the location on screen: keep the map, refresh behind it.
            snapshotNotice = nil
            resetPerScanState()
            coordinator.startRefreshScan(target, options: options)
        } else if !forcesRescan,
                  let info = cachedScanInfo[target.id],
                  shouldSkipAutoRescan(lastScanDuration: info.lastScanDuration) {
            // The policy says an unsolicited rescan would hurt (snapshot-only
            // always; smart when the last scan of this location took long):
            // display the snapshot and offer the rescan in a notice instead.
            displaySnapshotWithoutRescan(for: target, info: info)
        } else if coordinator.recentSnapshot(forTargetID: target.id) != nil {
            // Displayed earlier this session: the map appears instantly from
            // memory (startRefreshScan retains it and uses it as the
            // incremental baseline) — no disk decode, no transition screen.
            snapshotNotice = nil
            resetPerScanState()
            coordinator.startRefreshScan(target, options: options)
        } else if cachedScanInfo[target.id] != nil || !hasIndexedSnapshotCache {
            // A persisted snapshot exists (or the launch index isn't ready
            // yet and one might): show it as soon as it decodes, refreshing
            // behind it. A cache miss reverts to live partial streaming
            // within milliseconds. One decode feeds both the display and the
            // refresh scan's incremental baseline.
            snapshotNotice = nil
            resetPerScanState()
            let load = Task { [snapshotCache, kinds] in
                await Self.loadSeededSnapshot(for: target, in: snapshotCache, seeding: kinds)
            }
            coordinator.startRefreshScan(
                target,
                options: options,
                baselineProvider: { await load.value.snapshot }
            )
            restoreCachedSnapshot(for: target, canCancelRefresh: !forcesRescan, load: load)
        } else {
            snapshotNotice = nil
            resetPerScanState()
            coordinator.startScan(target, options: options)
        }
    }

    /// Whether the auto-rescan policy wants a cached snapshot displayed
    /// without an unsolicited refresh scan. Explicit rescans
    /// (forcesRescan: true) never consult this.
    private func shouldSkipAutoRescan(lastScanDuration: TimeInterval?) -> Bool {
        switch preferences?.autoRescanPolicy ?? .snapshotOnly {
        case .automatic:
            return false
        case .smart:
            guard let lastScanDuration else { return false }
            return lastScanDuration > Self.autoRescanMaxLastScanDuration
        case .snapshotOnly:
            return true
        }
    }

    /// Selection, zoom, and per-snapshot UI state reset before a new scan
    /// or snapshot takes the screen.
    private func resetPerScanState() {
        selectedNodeID = nil
        hoveredNodeID = nil
        zoomRootID = nil
        expandedNodeIDs = []
        expandedAggregateIDs = []
        kinds.reset()
        largest.reset()
        ages.reset()
        changes.reset()
        scanWasStopped = false
        warnings.reset()
    }

    /// Shows the persisted snapshot of a location without rescanning it.
    /// Falls back to a live scan when the snapshot turns out unreadable.
    private func displaySnapshotWithoutRescan(for target: ScanTarget, info: CachedScanInfo) {
        snapshotNotice = nil
        resetPerScanState()
        // Displayed earlier this session: skip the disk decode and restore
        // from memory in place — same notice, no loading state.
        if let recent = coordinator.recentSnapshot(forTargetID: target.id) {
            coordinator.restoreCompletedSnapshot(recent)
            syncCachedScanDate(with: recent)
            snapshotNotice = SnapshotNotice(
                targetID: target.id,
                scanDate: recent.finishedAt ?? recent.startedAt,
                lastScanDuration: info.lastScanDuration
            )
            snapshotWasRestoredWithoutRescan()
            return
        }
        coordinator.beginSnapshotRestore(target)
        Task { [weak self, snapshotCache] in
            let (cached, sidecar) = await Self.loadSeededSnapshot(
                for: target, in: snapshotCache, seeding: self?.kinds
            )
            guard let self else { return }
            guard self.coordinator.phase == .restoring,
                  self.coordinator.selectedTarget?.id == target.id else {
                return
            }
            if let cached {
                self.coordinator.completeSnapshotRestore(cached)
                self.syncCachedScanDate(with: cached)
                self.snapshotNotice = SnapshotNotice(
                    targetID: target.id,
                    scanDate: cached.finishedAt ?? cached.startedAt,
                    lastScanDuration: info.lastScanDuration
                )
                self.snapshotWasRestoredWithoutRescan()
                await Self.backfillKindStatsSidecarIfStale(
                    sidecar,
                    for: cached,
                    in: snapshotCache
                )
                self.kindStatsSidecarGeneration += 1
            } else {
                // Corrupt or vanished: forget the cache entry and scan live.
                self.cachedScanInfo.removeValue(forKey: target.id)
                self.coordinator.startScan(target, options: self.scanOptions(for: target))
            }
        }
    }

    /// The one way a cached snapshot is loaded for display: the kind-stats
    /// sidecar goes first (it is tiny next to the snapshot) and seeds the
    /// kind model before the decoded tree can land — the ordering that makes
    /// the first render colored instead of gray. Every restore path must
    /// come through here or it silently ships the gray-then-colored flash.
    private static func loadSeededSnapshot(
        for target: ScanTarget,
        in snapshotCache: ScanSnapshotCache,
        seeding kinds: KindStatsModel?
    ) async -> (snapshot: ScanSnapshot?, sidecar: KindStatsSidecar?) {
        let sidecar = await snapshotCache.loadAuxiliaryData(forTargetID: target.id)
            .flatMap(KindStatsSidecar.decoding)
        kinds?.prepareSeed(sidecar)
        let cached = await snapshotCache.loadSnapshot(for: target)
        return (cached, sidecar)
    }

    /// Persisted kind aggregates for a target's cached scan — the sidebar's
    /// volume bars color themselves from these without decoding the
    /// snapshot itself. nil when the target was never scanned (empty bar).
    func loadKindStatsSidecar(forTargetID targetID: String) async -> KindStatsSidecar? {
        await snapshotCache.loadAuxiliaryData(forTargetID: targetID)
            .flatMap(KindStatsSidecar.decoding)
    }

    /// Bumped whenever a kind-stats sidecar lands on disk. The sidecar is
    /// written asynchronously AFTER the snapshot save updates
    /// `cachedScanInfo` (it is an O(nodes) classification pass), so anyone
    /// reading sidecars reactively — the sidebar's volume bars — must key
    /// on this, not on the scan date, or they reload too early and miss it.
    private(set) var kindStatsSidecarGeneration = 0

    /// Snapshots cached before sidecars existed (or whose sidecar went
    /// stale) get one after display, so their next restore is seeded. Only
    /// the no-rescan endings need this — when a refresh scan keeps running,
    /// its finish writes a fresh sidecar through the save path.
    private static func backfillKindStatsSidecarIfStale(
        _ sidecar: KindStatsSidecar?,
        for cached: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        guard sidecar?.matches(cached) != true else { return }
        await saveKindStatsSidecar(for: cached, in: snapshotCache)
    }

    /// Computes and persists the kind-stats sidecar for a complete snapshot.
    /// Utility priority: this is the same O(nodes) classification pass a
    /// restore would otherwise pay at the worst moment.
    private static func saveKindStatsSidecar(
        for snapshot: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        let sidecarData = await Task.detached(priority: .utility) {
            try? KindStatsSidecar.make(for: snapshot).encoded()
        }.value
        guard let sidecarData else { return }
        await snapshotCache.saveAuxiliaryData(sidecarData, forTargetID: snapshot.target.id)
    }

    /// Computes and persists the Changes-tab diff for a just-saved snapshot
    /// against its now-rotated predecessor, mirroring the kind-stats sidecar.
    /// Utility priority and off the main actor: it decodes the predecessor
    /// and runs the O(nodes) build the tab would otherwise pay on first open.
    /// A no-op when there is no predecessor to diff against.
    private static func saveChangeListSidecar(
        for snapshot: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        let target = snapshot.target
        guard let previous = await snapshotCache.loadPreviousSnapshot(for: target) else { return }
        let currentStore = snapshot.treeStore
        let entryLimit = ChangesModel.entryLimit
        let list = await Task.detached(priority: .utility) {
            ScanChangeList.build(
                current: currentStore,
                previous: previous.treeStore,
                entryLimit: entryLimit
            )
        }.value
        await snapshotCache.saveChangeList(
            list,
            comparisonDate: previous.finishedAt,
            forTargetID: target.id,
            entryLimit: entryLimit
        )
    }

    /// A saved snapshot landed on screen with no refresh scan behind it, so
    /// no scan finish will run the usual conveniences — prefetch the Changes
    /// baseline and optionally start the duplicate scan here instead. (When
    /// a refresh runs behind the snapshot, its finish triggers both anyway.)
    private func snapshotWasRestoredWithoutRescan() {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return }
        diff.snapshotWasRestored(for: snapshot.target)
        // Prefer a persisted duplicate result over re-hashing: load the cached
        // run if present, and only start a fresh scan on a miss when the opt-in
        // preference is on. Relaunch never silently recomputes.
        duplicates.loadCachedResults(orScanIfMissing: preferences?.autoScanDuplicates == true)
    }

    /// The decoded snapshot is the on-disk truth. If the in-memory index
    /// disagrees (another Neodisk process wrote the cache, or the entry
    /// predates a failed save), adopt the snapshot's date so the sidebar's
    /// "Scanned … ago" matches what is actually displayed.
    private func syncCachedScanDate(with snapshot: ScanSnapshot) {
        let date = snapshot.finishedAt ?? snapshot.startedAt
        guard let info = cachedScanInfo[snapshot.target.id],
              abs(info.lastScanDate.timeIntervalSince(date)) > 1 else { return }
        cachedScanInfo[snapshot.target.id] = CachedScanInfo(
            lastScanDate: date,
            lastScanDuration: snapshot.finishedAt.map { $0.timeIntervalSince(snapshot.startedAt) },
            nodeCount: snapshot.treeStore.nodeCount,
            hasPreviousSnapshot: info.hasPreviousSnapshot,
            totalAllocatedSize: snapshot.aggregateStats.totalAllocatedSize,
            cloudOnlyLogicalSize: Self.cloudOnlyBytes(of: snapshot)
        )
    }

    private func restoreCachedSnapshot(
        for target: ScanTarget,
        canCancelRefresh: Bool = false,
        load: Task<(snapshot: ScanSnapshot?, sidecar: KindStatsSidecar?), Never>? = nil
    ) {
        Task { [weak self, snapshotCache] in
            let (cached, sidecar): (ScanSnapshot?, KindStatsSidecar?)
            if let load {
                (cached, sidecar) = await load.value
            } else {
                (cached, sidecar) = await Self.loadSeededSnapshot(
                    for: target, in: snapshotCache, seeding: self?.kinds
                )
            }
            guard let self else { return }
            if let cached {
                self.coordinator.displayCachedSnapshot(cached)
                // The pre-index launch race can start a refresh scan before
                // anything reveals that the last scan of this location was
                // expensive. The decoded snapshot itself carries the proof —
                // when the policy would have skipped the rescan (snapshot-only
                // always; smart for a slow last scan; never under automatic),
                // stop the unsolicited scan and offer it as a notice, same
                // as the indexed path would have.
                let lastDuration = cached.finishedAt.map { $0.timeIntervalSince(cached.startedAt) }
                self.syncCachedScanDate(with: cached)
                if canCancelRefresh,
                   shouldSkipAutoRescan(lastScanDuration: lastDuration),
                   self.coordinator.isScanning,
                   self.coordinator.snapshot?.id == cached.id {
                    self.coordinator.restoreCompletedSnapshot(cached)
                    self.snapshotNotice = SnapshotNotice(
                        targetID: target.id,
                        scanDate: cached.finishedAt ?? cached.startedAt,
                        lastScanDuration: lastDuration
                    )
                    self.snapshotWasRestoredWithoutRescan()
                    // The refresh was cancelled, so no scan finish will
                    // write the sidecar this snapshot is missing.
                    await Self.backfillKindStatsSidecarIfStale(
                        sidecar,
                        for: cached,
                        in: snapshotCache
                    )
                    self.kindStatsSidecarGeneration += 1
                } else if self.coordinator.isScanning, self.coordinator.snapshot?.id == cached.id {
                    FileHandle.standardError.write(
                        Data("Neodisk: showing cached scan of \(target.id) while the refresh runs\n".utf8)
                    )
                }
            } else {
                // Corrupt or vanished: forget it and let the live scan
                // stream — unless the scan finished during the probe and
                // just recorded a fresh snapshot for this very target.
                self.coordinator.abandonCachedSnapshotDisplay(forTargetID: target.id)
                let freshlyCompleted = self.coordinator.snapshot?.isComplete == true
                    && self.coordinator.snapshot?.target.id == target.id
                if !freshlyCompleted {
                    self.cachedScanInfo.removeValue(forKey: target.id)
                }
            }
        }
    }

    private func persistCompletedSnapshot(_ snapshot: ScanSnapshot) {
        guard snapshot.isComplete, snapshot.source.isPersistable else { return }
        // Saving usually rotates any existing latest snapshot into the
        // previous slot, so this target likely has a diffable previous scan
        // from now on if it had a cache entry before. Optimistic: an
        // unchanged rescan skips the rotation, and the save's outcome
        // corrects the entry (see saveSnapshotToCache).
        let hadCachedSnapshot = cachedScanInfo[snapshot.target.id] != nil
        cachedScanInfo[snapshot.target.id] = CachedScanInfo(
            lastScanDate: snapshot.finishedAt ?? Date(),
            lastScanDuration: snapshot.finishedAt.map { $0.timeIntervalSince(snapshot.startedAt) },
            nodeCount: snapshot.treeStore.nodeCount,
            hasPreviousSnapshot: hadCachedSnapshot,
            totalAllocatedSize: snapshot.aggregateStats.totalAllocatedSize,
            cloudOnlyLogicalSize: Self.cloudOnlyBytes(of: snapshot)
        )
        saveSnapshotToCache(snapshot)
    }

    /// Persists the displayed snapshot after a subtree splice (rescan of a
    /// folder or expansion of a summarized one) so reopening the location
    /// keeps the refreshed data. Unlike `persistCompletedSnapshot`, the
    /// cache index keeps the last full scan's date and duration: a subtree
    /// refresh says nothing about how long a full rescan of the location
    /// takes (the duration drives the auto-rescan decision) and the
    /// sidebar's "Scanned … ago" keeps describing the full scan. Only the
    /// node count is refreshed. Saving still rotates the pre-splice
    /// snapshot into the previous slot (unless the splice changed nothing),
    /// which keeps diffing meaningful: "what changed since before this
    /// refresh".
    private func persistSplicedSnapshot() {
        guard let snapshot = coordinator.snapshot,
              snapshot.isComplete, snapshot.source.isPersistable else { return }
        let existing = cachedScanInfo[snapshot.target.id]
        cachedScanInfo[snapshot.target.id] = CachedScanInfo(
            lastScanDate: existing?.lastScanDate ?? (snapshot.finishedAt ?? Date()),
            lastScanDuration: existing?.lastScanDuration,
            nodeCount: snapshot.treeStore.nodeCount,
            hasPreviousSnapshot: existing != nil,
            totalAllocatedSize: snapshot.aggregateStats.totalAllocatedSize,
            cloudOnlyLogicalSize: Self.cloudOnlyBytes(of: snapshot)
        )
        saveSnapshotToCache(snapshot)
    }

    private func saveSnapshotToCache(_ snapshot: ScanSnapshot) {
        Task { [weak self, snapshotCache] in
            do {
                let outcome = try await snapshotCache.save(snapshot)
                // The optimistic index entry guessed hasPreviousSnapshot
                // from "was there a cache entry"; the save knows the truth
                // (an unchanged rescan skips the rotation, so a target's
                // first rescan may leave the previous slot empty).
                self?.setHasPreviousSnapshot(
                    outcome.hasPreviousSnapshot, forTargetID: snapshot.target.id
                )
                if outcome.rotatedPrevious {
                    // Saving rotated the displayed scan's predecessor; an
                    // active diff of this target must rebase on it, and an
                    // inactive one may prefetch its baseline. A loaded Changes
                    // list compares against the replaced generation too.
                    self?.diff.snapshotWasRotated(for: snapshot.target)
                    self?.changes.snapshotWasRotated(for: snapshot.target)
                } else {
                    // Content-identical rescan: the previous slot (and any
                    // loaded baseline) still describes the right generation.
                    // Prefetch it for the fresh tree like a restore would.
                    self?.diff.snapshotWasRestored(for: snapshot.target)
                }
                // Kind stats ride along so the next restore of this
                // snapshot starts with a colored map.
                await Self.saveKindStatsSidecar(for: snapshot, in: snapshotCache)
                self?.kindStatsSidecarGeneration += 1
                // Compute and persist the change list now, off the main
                // actor, so the first open of the Changes tab is instant
                // instead of paying a predecessor decode plus O(nodes) build.
                await Self.saveChangeListSidecar(for: snapshot, in: snapshotCache)
            } catch {
                FileHandle.standardError.write(
                    Data("Neodisk: failed to persist scan snapshot: \(error)\n".utf8)
                )
            }
        }
    }

    private func bindPreferences() {
        guard let preferences else { return }
        freeSpace.preferences = preferences
        preferencesCancellable = preferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.freeSpace.update()
                self?.syncVizPalette()
                self?.syncVizViewMode()
                self?.syncCloudOnlyPreference()
            }
        freeSpace.update()
        syncVizPalette()
        syncVizViewMode()
        syncCloudOnlyPreference()
    }

    private func syncCloudOnlyPreference() {
        guard let preferences else { return }
        if showCloudOnlyFilesPreferred != preferences.showCloudOnlyFiles {
            showCloudOnlyFilesPreferred = preferences.showCloudOnlyFiles
        }
    }

    /// Mirror the persisted view-mode preference onto the model so the
    /// workspace and status bar follow the toolbar switcher.
    private func syncVizViewMode() {
        guard let preferences else { return }
        if vizViewMode != preferences.vizViewMode {
            vizViewMode = preferences.vizViewMode
        }
    }

    /// Push the palette to the kind catalog when the colorblind toggle flips.
    /// Kind colors are baked at build time, so the catalog rebuilds; age and
    /// treemap colors update reactively as views re-read `vizPalette`.
    private func syncVizPalette() {
        let palette = vizPalette
        if kinds.palette != palette {
            kinds.palette = palette
        }
    }

    /// Stops the running scan, keeping any partial results on screen. The
    /// scan strip stays up offering Resume when there is something to show.
    func stopScan() {
        let hadPartialResults = coordinator.snapshot != nil
        coordinator.stopScan()
        scanWasStopped = hadPartialResults
    }

    /// Rescans the stopped target from scratch (the engine has no traversal
    /// checkpointing, so "resume" is a fresh scan of the same location).
    func resumeScan() {
        guard let target = coordinator.selectedTarget else {
            scanWasStopped = false
            return
        }
        startScan(target, forcesRescan: true)
    }

    func dismissWelcome() {
        showWelcomeSheet = false
        preferences?.hasSeenWelcome = true
    }

    /// Rescans whatever location is currently open — the explicit ask that
    /// overrides the skipped auto-rescan of a large cached location.
    func rescan() {
        guard let target = coordinator.selectedTarget, !coordinator.isScanning else { return }
        startScan(target, forcesRescan: true)
    }

    /// Opens a "smaller items" cell: its folder's children render
    /// individually from now on.
    func expandAggregate(inFolder folderID: String) {
        expandedAggregateIDs.insert(folderID)
    }

    /// Adds a folder to the sidebar (persisted) and starts scanning it.
    /// Built-in locations (volumes and cloud) are already in the sidebar
    /// and never join the Folders section.
    func chooseFolderAndScan() {
        guard let target = SystemIntegration.presentScanPanel() else { return }
        let isBuiltInLocation = builtInLocations.contains { $0.id == target.id }
        if !isBuiltInLocation, !sidebarFolders.contains(where: { $0.id == target.id }) {
            sidebarFolders.append(target)
            sidebarFolderStore.add(target)
        }
        startScan(target)
    }

    /// Handles folders dropped onto the window or the sidebar: adds each
    /// one to the Folders section (same rules as Add Folder… — built-in
    /// locations and duplicates are skipped) and starts scanning the
    /// first. Non-folder drops are ignored.
    @discardableResult
    func addDroppedFolders(_ urls: [URL]) -> Bool {
        let folderURLs = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !folderURLs.isEmpty else { return false }

        let builtInIDs = Set(builtInLocations.map(\.id))
        var firstTarget: ScanTarget?
        for url in folderURLs {
            let target = ScanTarget(url: url)
            if firstTarget == nil { firstTarget = target }
            if !builtInIDs.contains(target.id),
               !sidebarFolders.contains(where: { $0.id == target.id }) {
                sidebarFolders.append(target)
                sidebarFolderStore.add(target)
            }
        }
        if let firstTarget {
            startScan(firstTarget)
        }
        return true
    }

    func removeSidebarFolders(ids: Set<String>) {
        for target in sidebarFolders where ids.contains(target.id) {
            sidebarFolderStore.remove(target)
        }
        sidebarFolders.removeAll { ids.contains($0.id) }

        // A removed folder loses its persisted snapshot too — unless it is
        // also a built-in location, which keeps its own cache entry.
        let removedIDs = ids.subtracting(builtInLocations.map(\.id))
        guard !removedIDs.isEmpty else { return }
        for id in removedIDs {
            cachedScanInfo.removeValue(forKey: id)
            coordinator.forgetRecentSnapshot(forTargetID: id)
        }
        Task { [snapshotCache] in
            for id in removedIDs {
                await snapshotCache.removeSnapshot(forTargetID: id)
            }
        }
    }

    /// The previous snapshot of a target turned out to be unreadable or
    /// gone; reflect that in the cache index so the diff toggle disables.
    func markPreviousSnapshotMissing(forTargetID targetID: String) {
        setHasPreviousSnapshot(false, forTargetID: targetID)
    }

    /// Cloud-only bytes below a snapshot's root, carried into
    /// `cachedScanInfo` so the sidebar's cloud bar works without decoding.
    private static func cloudOnlyBytes(of snapshot: ScanSnapshot) -> Int64 {
        let store = snapshot.treeStore
        return store.node(id: store.rootID)?.cloudOnlyLogicalSize ?? 0
    }

    private func setHasPreviousSnapshot(_ hasPrevious: Bool, forTargetID targetID: String) {
        guard let info = cachedScanInfo[targetID],
              info.hasPreviousSnapshot != hasPrevious else { return }
        cachedScanInfo[targetID] = CachedScanInfo(
            lastScanDate: info.lastScanDate,
            lastScanDuration: info.lastScanDuration,
            nodeCount: info.nodeCount,
            hasPreviousSnapshot: hasPrevious,
            totalAllocatedSize: info.totalAllocatedSize,
            cloudOnlyLogicalSize: info.cloudOnlyLogicalSize
        )
    }

    /// Cache-index bookkeeping for a removed location (a signed-out cloud
    /// account); moves to the scan session model with the rest of the index.
    func removeCachedScanInfo(forTargetID targetID: String) {
        cachedScanInfo.removeValue(forKey: targetID)
    }

    // MARK: - Snapshot cache maintenance

    /// Total disk usage of persisted snapshots, for Settings → Privacy.
    func scanSnapshotCacheSize() async -> Int64 {
        await snapshotCache.totalSizeOnDisk()
    }

    func clearScanSnapshots() async {
        await snapshotCache.removeAll()
        cachedScanInfo = [:]
        coordinator.forgetAllRecentSnapshots()
    }

    private func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        freeSpace.update()

        diff.snapshotDidChange(snapshot)

        // The kind and age catalogs, the drilled-in lists, and the shared
        // search index are all keyed to the replaced tree.
        searchIndexService.invalidate()
        kinds.snapshotDidChange(snapshot)
        largest.snapshotDidChange()
        ages.snapshotDidChange(snapshot)
        duplicates.snapshotDidChange()
        changes.snapshotDidChange()
        search.snapshotDidChange()

        guard let snapshot else { return }

        // Expand the root row by default so the outline isn't a single line.
        expandedNodeIDs.insert(snapshot.treeStore.root.id)
    }

    // MARK: - Subtree refresh

    /// Gate for the context-menu subtree action: nothing else may be
    /// scanning, restoring, or expanding.
    var canRefreshSubtree: Bool {
        !coordinator.isScanning
            && coordinator.phase != .restoring
            && coordinator.expandingNodeID == nil
    }

    /// The contents-expansion context-menu command a node offers, if any.
    /// Both kinds funnel into `expandNodeContents`; only the wording (and
    /// the reason the contents are missing) differs.
    enum ContentsExpansion {
        /// An auto-summarized folder — "Expand Contents".
        case summarizedFolder
        /// A still-opaque package — Finder's "Show Package Contents".
        case package

        var menuTitleKey: String {
            switch self {
            case .summarizedFolder: "Expand Contents"
            case .package: "Show Package Contents"
            }
        }
    }

    /// The expansion command to offer `node` in a context menu, or nil.
    /// Every menu (outline, treemap, sunburst chart + legend, file lists)
    /// derives its item from this one gate so they cannot drift. An already
    /// expanded package has children in the store and offers nothing.
    func contentsExpansion(for node: FileNodeRecord) -> ContentsExpansion? {
        if node.isAutoSummarized { return .summarizedFolder }
        if node.isPackage, node.isDirectory, store?.containsChildren(id: node.id) != true {
            return .package
        }
        return nil
    }

    /// Scans an auto-summarized folder's or an opaque package's real
    /// contents and splices them in — the context menu's "Expand Contents" /
    /// "Show Package Contents".
    func expandNodeContents(_ node: FileNodeRecord) {
        guard canRefreshSubtree else { return }
        // Match the on-screen scan's options (a volume scan forces hidden
        // files on) so the spliced subtree isn't missing entries it had.
        var options = coordinator.snapshot.map { scanOptions(for: $0.target) }
            ?? preferences?.scanOptions ?? ScanOptions()
        if node.isAutoSummarized {
            // The user explicitly asked for this folder's contents;
            // re-summarizing it would make the action a no-op.
            options.autoSummarizeDirectories = false
        } else {
            // Show Package Contents: open this one package — bundles nested
            // inside stay opaque (each individually expandable), and huge
            // interior folders may still auto-summarize per the usual rules.
            options.treatRootPackageAsDirectory = true
        }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.coordinator.expandNodeContents(node, options: options)
            self.handleSubtreeRefresh(result)
        }
    }

    private func handleSubtreeRefresh(_ result: ScanExpansionResult) {
        switch result {
        case .expanded(let replacementRootID):
            revealInOutline(replacementRootID)
            expandedNodeIDs.insert(replacementRootID)
            persistSplicedSnapshot()
        case .failed(let message):
            actionErrorMessage = message
        case .skipped, .cancelled:
            break
        }
    }

}
