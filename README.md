# Wau

A calm, Arc-style browser for macOS, named after the *wau bulan*, the moon kite
of Malaysia's east coast. Built natively with Swift, AppKit and WKWebView.

## Features

- **Vertical sidebar**: favorites grid, the Space's pinned tabs, "+ New Tab", its
  other tabs and its Easels. Drag tabs to reorder; drag across "New Tab" to pin or unpin.
- **Spaces**: each with its own emoji, theme, tabs and archive setting, and
  optionally separate logins (its own cookies and site data). Switch with the
  buttons at the bottom of the sidebar, ⌃1–⌃9, ⌥⌘←/→ or a two-finger swipe.
- **Malaysian themes**: Wau Bulan, Langkawi, Cameron, Melaka, Kinabalu,
  Songket, Batik and Nyonya.
- **Command bar** (⌘T, ⌘L): addresses, search, open tabs in every Space,
  history ranked by frequency and recency, archived tabs, and commands.
- **Auto-archive**: ordinary tabs you haven't looked at for 12 hours (or a
  day, week, month, or never, per Space) are archived. Bring them back from the
  command bar or History ▸ Archived Tabs, with their history.
- **Split View**: 2–4 tabs side by side or stacked (⌃⇧=, right-click ▸ Open
  in Split View). Click a pane to focus it; drag the gaps to resize.
- **Little Wau**: a compact window for quick looks (⌥⌘N) and for links
  from other apps when Wau is your default browser. ⌘O moves the page into the main window.
- **Easels**: canvases for clippings (⇧⌘2 to clip part of a page), page
  links and labels. Paste or drop images and links; drag, resize, delete.
- **Google Drive sync**: Spaces, pinned tabs, favorites and Easels sync through
  a private app folder in your Drive. Open tabs, history and logins stay local.
- Also: tabs restore on relaunch with their history (pages load when first
  shown), site icons, downloads to ~/Downloads, find in page, page zoom,
  reopen closed tabs, Inspect Element.

## Keyboard shortcuts

| | |
|---|---|
| ⌘T / ⌘L | Command bar: new tab / change this tab's page |
| ⌘W / ⇧⌘T | Close tab (pinned tabs reset instead) / reopen closed tab |
| ⌘D | Pin or unpin tab |
| ⌘S | Show or hide the sidebar |
| ⌘1–⌘8, ⌘9 | Go to tab 1–8 / the last tab |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌃1–⌃9, ⌥⌘← / ⌥⌘→ | Go to Space 1–9 / previous / next Space |
| ⌃⇧= / ⌃⇧- | Add a Split View pane / remove the focused pane |
| ⇧⌘2 | Clip part of the page to an Easel |
| ⌥⌘N | New Little Wau window |
| ⌘F, ⌘G, ⇧⌘G | Find in page, next, previous |
| ⌘+ / ⌘- / ⌘0 | Zoom in / out / actual size |
| ⇧⌘C | Copy page link |
| ⌘, | Settings |

## Build and run

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate          # creates Wau.xcodeproj from project.yml
open Wau.xcodeproj         # then ⌘R in Xcode, or:
xcodebuild -project Wau.xcodeproj -scheme Wau -derivedDataPath build build
open build/Build/Products/Debug/Wau.app
```

Run `xcodegen generate` again after adding or removing source files.

## Tests

```sh
tools/test.sh   # Core, Storage and Sync packages, then the app's own tests
```

## Google Drive sync setup

Sync needs a Google OAuth client ID compiled into the app:

1. In [Google Cloud Console](https://console.cloud.google.com/), create a
   project and enable the **Google Drive API**.
2. Configure the **OAuth consent screen** and add your Google account as a test user.
3. Create credentials ▸ **OAuth client ID** of type **iOS**, with bundle ID `dev.wau.Wau`.
4. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, paste the
   client ID, and rebuild. (`Local.xcconfig` isn't committed.)
5. In Wau: Settings ▸ Sync ▸ Sign in with Google.

While the consent screen is in "Testing" mode, Google expires the sign-in
after 7 days; Wau then asks you to sign in again. Publishing the consent
screen (Google verification) removes that limit.

## Packaging

```sh
tools/package.sh   # Release build → dist/Wau-<version>.dmg (ad-hoc signed)
```

To run on other Macs without security warnings, sign and notarize with an
Apple Developer account:

```sh
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=wau-notary tools/package.sh
```

## App icon

The current icon is pixel art generated with `agy` (candidates in `design/icon/`). Install one with
`tools/make-icon.sh design/icon/<file>.png`, or run `tools/make-icon.sh` with no argument
for the vector version drawn by `tools/make-icon.swift`. Either way the script will
regenerate every size in `App/Resources/Assets.xcassets/AppIcon.appiconset`.

## Layout

- `App/`: the AppKit app
  - `Browser/`: tabs, the browser model (Spaces, splits, archive), history, icons, downloads
  - `Window/`: the main window and its features (command bar, Spaces, Split View, Easels, find)
  - `Sidebar/`, `CommandBar/`, `Easels/`, `LittleWau/`, `Settings/`, `Sync/`
- `Packages/Core/`: UI-free logic: URL input, themes, ranking, archive rules,
  split groups, sync merging and mapping
- `Packages/Storage/`: the SQLite database ([GRDB](https://github.com/groue/GRDB.swift)) and Easel image files
- `Packages/Sync/`: Google sign-in (OAuth + PKCE), the Drive client, the sync engine
- `AppTests/`: tests of the browser model and stores, run inside the app

Data lives in `~/Library/Application Support/Wau/` (`wau.sqlite` and
`EaselImages/`). The Google sign-in is kept in the login keychain.
