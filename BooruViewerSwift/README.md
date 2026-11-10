# Booru Viewer (SwiftUI)

Native SwiftUI app, iOS-only, with no external package manager. This standalone export contains
the native Swift implementation only; an earlier React Native implementation is not included.

## Requirements

- macOS with Xcode 15.4 or newer (Xcode 16 works too)
- iOS 17.0+ deployment target, iPhone only
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

`BooruViewer.xcodeproj` is generated and not committed. Regenerate it after changing
`project.yml` or adding files:

```sh
cd BooruViewerSwift
xcodegen generate
```

## Build and test

```sh
cd BooruViewerSwift
xcodebuild test -project BooruViewer.xcodeproj -scheme BooruViewer \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

To build without running tests, use `xcodebuild build -project BooruViewer.xcodeproj -scheme BooruViewer -destination 'generic/platform=iOS Simulator'`.

Secrets (Gelbooru / Rule34 API keys, app-lock hash) live in the Keychain and are never written
to the JSON stores. The app connects to public adult sites; use a simulator or device allowed to
reach them.

## Module layout

`Sources/` is compiled as one application target:

- `App/` — `BooruViewerApp` (`@main`), `AppContainer` (shared stores, services, credentials),
  `RootTabView` (four tabs, viewer cover, tag navigation, lock overlay).
- `Core/Contracts/` — protocols and value types shared by every layer (`BooruSource`,
  `SourceContext`, `SourceRegistry`, `AppSettings`, persistence protocols).
- `Core/Models/` — `BooruPost`, `SearchQuery`, `SourceID`, filtering and media models.
- `Core/Network/` — `URLSessionHTTPClient`, proxy relay/fallback, rate limiting, retries.
- `Core/Filtering/` — blacklist matching.
- `Booru/` — Gelbooru/Rule34, Danbooru, and Moebooru JSON adapters.
- `Scrapers/` — Realbooru, XVideos, XHamster, Sex.com, and Pornhub HTML scrapers, plus the
  WebKit Pornhub challenge solver.
- `SourcesAPI/` — Cum.st, RedGifs, NHentai, and HentaiHaven API adapters.
- `Storage/` — atomic `JSONFileStore` actor and the settings/favorites/tag/history/recent-view
  stores, plus the Keychain wrapper.
- `Security/` — passcode hashing, biometrics, and the app-lock scene-phase controller.
- `Backup/` — native JSON and legacy AnimeBoxes `.abbj` import/export.
- `Media/`, `UI/` — image quality resolution, video candidate selection, theme, and shared views.
- `Features/` — one folder per screen with its `@Observable` view model (`Feed`, `Search`,
  `Favorites`, `Viewer`, `Settings`, `Lock`).

`Tests/` mirrors those areas and runs against the `BooruViewer` target via `@testable import
BooruViewer`. `Tests/App/SourceRegistryTests.swift` verifies every `SourceID` resolves to a
matching source.
