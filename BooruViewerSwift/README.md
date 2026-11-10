# Booru Viewer (SwiftUI)

Native iOS 26 SwiftUI app (Liquid Glass navigation, `.searchable`, grouped `Form`/`List` views,
and native Apple `AVPlayerViewController` playback), iPhone-only, with no external package
manager. This standalone export contains the native Swift implementation only; an earlier React
Native implementation is not included.

> **18+ only.** This app is a reader for adult content sites. It does not host or bundle any
> media, ships with no credentials, and is not affiliated with any source. MIT License (see
> `../LICENSE`).

## Requirements

- macOS with **Xcode 26** or newer and matching **iOS 26 SDK**
- **iOS 26.0+** deployment target, iPhone only
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

`BooruViewer.xcodeproj` is generated and not committed. Regenerate it after changing
`project.yml` or adding files:

```sh
cd BooruViewerSwift
xcodegen generate
```

## Build, unsigned IPA, and test

```sh
cd BooruViewerSwift
xcodebuild test -project BooruViewer.xcodeproj -scheme BooruViewer \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

To build for simulator without running tests:
`xcodebuild build -project BooruViewer.xcodeproj -scheme BooruViewer -destination 'generic/platform=iOS Simulator'`.

To build an unsigned device `.ipa` locally (mirroring `.github/workflows/build-swift-ios.yml`):
build `Release` with `-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS=""`,
then package the `.app` under `Payload/` into a `.ipa` zip archive. Re-sign with your own
certificate and provisioning profile before installing on a device.

### Current verification status

- Local branch `feat/ios26-native-ui` has **no CI run yet**; a fresh Xcode 26 / iOS 26 device
  build and current unsigned `.ipa` are **pending**.
- Prior test counts (such as earlier 239 or 232 counts) are **outdated** and **not proof** of
  the new iOS 26 native UI or `AVPlayerViewController` changes.
- Special UI test suites for delayed reader extent (`MangaScrollUITests`, `-mangaFixture`) and
  native video scrubber arbitration (`NativePlayerInteractionUITests`, `-videoFixture`) are
  **pending deterministic fixture wiring** and intentionally `XCTSkip`.

Secrets (Gelbooru / Rule34 API keys, app-lock hash) live in the Keychain and are never written
to the JSON stores. The app connects to public adult sites; use a simulator or device allowed to
reach them, and only where accessing such content is legal for you.

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
- `Media/`, `UI/` — image quality resolution, video candidate selection, semantic `AppTheme`,
  `NativeVideoPlayerView` (`AVPlayerViewController` + `NativePlaybackLifecycle`), and shared views.
- `Features/` — one folder per screen with its `@Observable` view model (`Feed`, `Search`,
  `Favorites`, `Viewer`, `Settings`, `Lock`).

`Tests/` mirrors those areas and runs against the `BooruViewer` target via `@testable import
BooruViewer`. `Tests/App/SourceRegistryTests.swift` verifies every `SourceID` resolves to a
matching source. `UITests/` contains real-gesture XCUITest suites (`AppInteractionUITests` plus
fixture-gated `NativePlayerInteractionUITests` and `MangaScrollUITests`).
