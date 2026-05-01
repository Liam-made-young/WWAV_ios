# WWAV iOS

SwiftUI iOS app for WWAV music, image, text, and video posts.

## Project Source Of Truth

`project.yml` is the intended project definition. Regenerate the Xcode project after changing targets, build settings, or file layout:

```sh
xcodegen generate
```

## Build And Test

```sh
xcodebuild -project WWAV.xcodeproj -scheme WWAV -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -project WWAV.xcodeproj -scheme WWAV -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Environment

Production API traffic defaults to `https://www.mi-wwav.com`. For local or staging builds, set `WWAVAPIBaseURL` in `Info.plist`; the app reads it through `AppEnvironment.current`.

The local Demucs helper lives in `demucs_server/`.
