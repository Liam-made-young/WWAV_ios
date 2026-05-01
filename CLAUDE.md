# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Project Generation

This project uses **XcodeGen** — the `WWAV.xcodeproj` is generated from `project.yml`. After modifying `project.yml`, regenerate with:

```bash
xcodegen generate
```

Build from command line (requires Xcode CLI tools):

```bash
xcodebuild -project WWAV.xcodeproj -scheme WWAV -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' build
```

There are no tests, no Makefile, no Fastfile, and no CI workflows in this repository.

## Architecture

**MVVM + SwiftUI environment injection.** Five `@StateObject` instances are created at the app root (`WWAVApp.swift`) and injected as `@EnvironmentObject` into child views:

| Object | Role |
|---|---|
| `AuthManager` | JWT token (keychain), login/logout, session restore |
| `TrackLibrary` | Master app state: track list, feed, local edits, tombstones, server sync |
| `StemPlayerEngine` | AVAudioEngine 4-stem mixer, per-stem volume, lock-screen transport |
| `AppNavigation` | Active tab, active post routing (music → stem player, video → AVPlayer) |
| `ThemeManager` | Palette selection, persisted to UserDefaults |

The theme is injected separately via `@Environment(\.theme)` using a custom `EnvironmentKey`.

## Code Layout

```
WWAV/
├── WWAVApp.swift              # @main, DI root
├── Audio/                     # Stem separation + playback
├── Library/                   # Business logic (TrackLibrary, AuthManager, API, AppNavigation, Persistence)
├── Models/                    # Data structs (Track, User, AuthModels, CommentModels)
├── Storage/                   # StorageService protocol + LocalDiskStorage
├── Theme/                     # ThemeManager, Palette, Theme modifiers
└── Views/                     # SwiftUI views + Components/
```

`DESIGN/` contains JSX/Figma reference files — not part of the Swift build.  
`demucs_server/` is a FastAPI Python service for local stem separation.

## Key Domain Concepts

**Track post kinds:** `.music` (4-stem cloud upload), `.image` (carousel), `.text` (local-only), `.video` (local-only).

**Stem separation:** `StemSeparationService` protocol has two implementations:
- `MiWwavStemService` — production cloud via `https://www.mi-wwav.com` + Replicate/htdemucs
- `LocalDemucsService` — connects to the bundled `demucs_server/` FastAPI on localhost (Mac dev)

**Upload flow:** sign S3 URL → PUT to S3 → POST `/api/upload/process` → poll `/api/user/uploads` until `status="ready"` → download 4 stems.

## Persistence Strategy

| Data | Storage |
|---|---|
| Auth JWT | Keychain (`kSecAttrAccessibleAfterFirstUnlock`) |
| Deleted post IDs (tombstones) | Keychain (survives reinstall) |
| Local title/bio/cover edits | Keychain |
| Track library | JSON in Application Support (`wwav/library.json`) |
| Audio files / uploads | Application Support (`wwav/objects/uploads/`) |
| Stem cache | Application Support (`stems/<trackId>/`) |
| Theme palette | UserDefaults |

`TrackLibrary` handles merge logic: server tracks are deduplicated via `remoteTrackId`, tombstoned IDs are filtered out, and local edits overlay server metadata.

## Theming

Four palettes: `lightBlue` (default), `sage`, `royalPurple`, `orange`. Each defines 10 named colors + radial gradient builders in `Palette.swift`. Views should use `@Environment(\.theme)` and the `.themed()` / `.themedText()` modifiers from `Theme.swift`.

## Backend

Base URL: `https://www.mi-wwav.com`. All requests go through `API.swift` with Bearer token auth. Social features (likes, comments) use optimistic UI — update state immediately, revert on network error.

## No Third-Party Dependencies

The project uses only built-in Apple frameworks: SwiftUI, AVFoundation, MediaPlayer, SceneKit, Combine, Security. There is no CocoaPods, Carthage, or Swift Package Manager.
