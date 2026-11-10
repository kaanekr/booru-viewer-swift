# Booru Viewer (SwiftUI)

A native iOS client for browsing imageboard-style and video sites through their public APIs
and public web pages. SwiftUI, iOS 17+, iPhone only, no third-party Swift packages.

> **18+ only.** This app is a reader for adult content sites. It does not contain, host, or
> bundle any media, and it ships with no credentials.

## What it is

- One application target in `BooruViewerSwift/Sources/`, split into contracts, network,
  source adapters (JSON APIs and HTML scrapers), storage, security, media, UI, and screens.
- Unit tests in `BooruViewerSwift/Tests/`, UI tests in `BooruViewerSwift/UITests/`.
- Demo mode (`-demoMode` launch argument) uses neutral placeholder imagery so screens can be
  exercised without contacting any network source.

## Build

Requires macOS with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd BooruViewerSwift
xcodegen generate
```

`BooruViewer.xcodeproj` is generated from `project.yml` and is not committed; regenerate it
after changing `project.yml` or adding files. Then build or test:

```sh
xcodebuild build -project BooruViewer.xcodeproj -scheme BooruViewer \
  -destination 'generic/platform=iOS'
xcodebuild test -project BooruViewer.xcodeproj -scheme BooruViewer \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Unsigned IPA

`.github/workflows/build-swift-ios.yml` builds an unsigned device `.ipa` on a stock
`macos-26` GitHub runner, and separately runs the unit tests, the UI tests, and a screenshot
smoke run. The uploaded IPA has no signature, no provisioning profile, and no entitlements:
it must be re-signed with your own certificate and profile before it can be installed on a
device. Nothing here produces an App Store submission or a notarized build.

## Limitations, honestly

This is a client for third-party services, so its reliability is bounded by theirs:

- Sources are implemented against public endpoints and public page markup. When a site
  changes its HTML, blocks requests, or rate-limits, that source can break until the adapter
  is updated. Working adapters are not a guarantee of future availability.
- Some sources require credentials you supply yourself (for example a user ID and API key),
  and some are anonymous. Credentials are stored in the iOS Keychain, never in the JSON
  stores. Missing credentials mean missing results, not an error dialog.
- Optional proxy support expects a user-deployed relay URL. Without one, requests go direct.
- Video playback, HLS, and some image formats depend on what the OS decoder accepts; a
  candidate URL is not proof that a given file plays.
- The UI test and screenshot jobs are simulator smoke runs. They are not a statement that
  every screen or gesture is verified on every device.
- Expect to re-sign the IPA yourself, and expect some sources to be unavailable depending on
  your region or network.

## Legal and affiliation

This project is not affiliated with, endorsed by, or supported by any of the sites or
services it can read. All names, marks, and content belong to their respective owners.
You are responsible for complying with the laws that apply to you and with each service's
terms of use. Use it only where accessing such content is legal for you.

## License

MIT, see [`LICENSE`](LICENSE). Copyright (c) 2026 Booru Viewer Contributors. If you
redistribute or fork this in whole or in part, keep the copyright notice and permission
notice from `LICENSE` with your copy.
