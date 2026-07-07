<p align="center">
  <img src="Packaging/icon.png" width="128" alt="Neodisk icon">
</p>

<h1 align="center">Neodisk</h1>

<p align="center">
  Read-only MacOS disk space visualizer
  Treemap on the <code>NeodiskKit</code> scan engine.
</p>

---

**Read-only by design.** Neodisk never modifies or deletes your files. 
Instead, Reveal in Finder, Open, and Copy Path are the only file actions.
Delete and clean up in Finder.

## Features

- **Treemap** — Pinch to zoom, scroll to pan.
- **Outline + file type statistics** — size-sorted file tree and per-type totals
- **Fast scanning** — parallel traversal that backs off as the machine
  heat-soaks, hard-link dedup, live progress, glob exclusions.
- **Find anything** — `⌘F` fuzzy search over the entire scan. Quick Look on spacebar.
- **Snapshots & changes** — completed scans persist and reopen instantly. The Changes (+/-)
  toggle diffs against the previous scan to show what files grew, shrinked, got added, deleted.
- **Multilingual** — the UI follows the macOS system language: English, Spanish,
  French, German, Italian, Brazilian Portuguese, Japanese, and Simplified Chinese.

## Build & Run

Requires macOS 14+ and a Swift 6 toolchain. No Xcode needed, the Xcode
Command Line Tools are enough.

```bash
swift run -c release Neodisk    # build and launch directly
swift test                      # full test suite (engine + treemap + UI)
```

## Structure

One package, strictly layered targets:

```
Sources/
├── NeodiskKit/   # UI-free scanning core: ScanEngine, contiguous
│                 #   Int32-indexed file tree store, snapshots/cache,
│                 #   hard-link dedup (derived from Radix)
├── NeodiskCLI/   # `diskscan` — the core's reference CLI
├── TreemapKit/   # Pure treemap geometry: squarified layout, viewport,
│                 #   cushion cell model + parallel rasterizer
├── NeodiskUI/    # The app: SwiftUI/AppKit views, view model, scan lifecycle
└── Neodisk/      # Thin executable entry point

Localization/     # .lproj string catalogs (one per language), copied into
                  #   the .app bundle at package time
```

## Planned

- Horizontal scroll in the file outline — undecided. The itch: deep nesting
  crops names until the sidebar is very wide, but the current behavior is
  acceptable. If done, it must not interfere with search (same pane).
- Multiplatform: native Windows and Linux versions (a lot of work, will
  take a while).

## Credits

- [Radix](https://github.com/colinvkim/Radix) by Colin Kim (MIT) — the scan
  engine, core data model NeodiskKit is derived from, huge inspiration.
- [Disk Inventory X](http://www.derlien.com/) by Tjark Derlien and
  [GrandPerspective](https://grandperspectiv.sourceforge.net/) by Erwin
  Bonsma — the cushion-treemap disk viewers this UI follows. No code from
  either is used.
- Cushion treemaps: van Wijk & van de Wetering, INFOVIS 1999. Squarified
  treemaps: Bruls, Huizing & van Wijk, 2000.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE); Radix attribution is preserved there.
