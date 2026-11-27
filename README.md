# Wau

A calm, Arc-style browser for macOS, named after the *wau bulan*, the moon kite
of Malaysia's east coast. Built natively with Swift, AppKit and WKWebView.

## Features

- **Vertical sidebar**: favorites grid, the Space's pinned tabs, "+ New Tab", its
  other tabs, then its Easels as tabs too. Drag tabs to reorder; drag across
  "New Tab" to pin or unpin.
- **Spaces**: each with its own emoji, theme, tabs and archive setting, and
  optionally separate logins (its own cookies and site data). Switch with the
  buttons at the bottom of the sidebar, ⌃1–⌃9, ⌥⌘←/→ or a two-finger swipe.
- **Malaysian themes**: Wau Bulan, Langkawi, Cameron, Melaka, Kinabalu,
  Songket, Batik and Nyonya.
- **Command bar** (⌘T, or click the address field to change this tab's
  page): addresses, search, open tabs in every Space, history ranked by
  frequency and recency, archived tabs, and commands.
- **Auto-archive**: ordinary tabs you haven't looked at for 12 hours (or a
  day, week, month, or never, per Space) are archived. Bring them back from the
  command bar or History ▸ Archived Tabs, with their history.
- **Split View**: 2–4 tabs side by side or stacked (⌃⇧=, right-click ▸ Open
  in Split View, or drag a tab from the sidebar onto the left or right half
  of the page, or onto the left or right half of another tab in the sidebar).
  Click a pane to focus it; drag the gaps to resize. In the
  sidebar a split is one row with a segment per pane: click a segment to
  focus that pane, or drag it out into the list to take it out of the split.
  Easels can join a split too: drag one beside a tab, on the page or in the
  sidebar (a split always keeps at least one tab).
- **Blank and Incognito windows**: ⌃⌘N opens an empty extra window and
  ⇧⌘N a private one. Their tabs go when they close. Incognito keeps no
  history, and its cookies, logins and caches stay in memory only. Drag a tab
  out of the sidebar onto the desktop to move it into a new Blank Window
  (an incognito one, from an incognito window), and into another window's
  sidebar or page to move it back; a window left without tabs closes.
  Incognito tabs only move between incognito windows.
- **Little Wau**: a compact window for quick looks (⌥⌘N) and for links
  from other apps when Wau is your default browser. ⌘O moves the page into the main window.
- **Easels**: canvases for clippings, page links, text, shapes and
  drawings. The toolbar along the bottom has Select (V), Add Image, Text (T),
  Circle (O), Rectangle (R), Arrow (A), Draw (P), Colour (recolours the
  selected label or drawing, and is used for new ones) and Clip, which clips part of
  a page onto the Easel (⇧⌘2 does the same from any page). Hold ⇧ for a
  perfect circle or square, Esc puts the tool down. Paste or drop images and
  links; drag to move, drag any edge or corner to resize, ⌫ to delete. Label text grows and shrinks with its box;
  select a label and use the + / − pop-up beside it to pick a size instead
  (Aa goes back to filling the box). Pinch or ⌘+ / ⌘- / ⌘0 to zoom; rename an Easel
  from its right-click menu in the sidebar. Pin an Easel like a tab (right-click ▸
  Pin Tab, ⌘D while it's open, or drag it above "New Tab").
- **Google Drive sync**: Spaces, pinned tabs, favorites and Easels sync through
  a private app folder in your Drive. Open tabs, history and logins stay local.
- Also: tabs restore on relaunch with their history (pages load when first
  shown), site icons, downloads to ~/Downloads, find in page, page zoom,
  reopen closed tabs, Inspect Element.

## Keyboard shortcuts

| | |
|---|---|
| ⌘T | Command bar for a new tab |
| ⌘W / ⇧⌘T | Close tab (pinned tabs reset instead) / reopen closed tab |
| ⌘D | Pin or unpin tab |
| ⌘S | Show or hide the sidebar |
| ⌘1–⌘8, ⌘9 | Go to tab 1–8 / the last tab |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌃1–⌃9, ⌥⌘← / ⌥⌘→ | Go to Space 1–9 / previous / next Space |
| ⌃⇧= / ⌃⇧- | Add a Split View pane / remove the focused pane |
| ⇧⌘2 | Clip part of the page to an Easel |
| ⌃⌘N / ⇧⌘N | Blank window / new Incognito window |
| ⌥⌘N | New Little Wau window |
| ⌘F, ⌘G, ⇧⌘G | Find in page, next, previous |
| ⌘+ / ⌘- / ⌘0 | Zoom the page or Easel in / out / actual size |
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
