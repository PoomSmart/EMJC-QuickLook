# EMJC Quick Look

A macOS Quick Look extension that previews emoji TTC fonts containing Apple's proprietary **EMJC** image format (used in `AppleColorEmoji.ttc`). Shows a curated 30-glyph grid matching the macOS Font Book layout.

The extension claims a custom file type (`.ettc`) rather than the system-wide `.ttc` UTI, so regular font collections (Helvetica.ttc etc.) are unaffected.

## Requirements

- macOS 12.4 (Monterey) or later
- Xcode 16 or later (to build from source)

## How Quick Look extensions work

Modern Quick Look extensions (`.appex`) must be embedded inside a host app bundle — unlike the old `.qlgenerator` plug-ins, they cannot be installed standalone. macOS discovers and registers the extension automatically when the host app is placed in `/Applications` or `~/Applications`.

## Build from source

```sh
git clone <repo>
cd EMJC
open EMJC.xcodeproj
```

In Xcode:

1. Select the **EMJC** scheme and a macOS destination.
2. **Product → Build** (⌘B) for local testing, or **Product → Archive** for a distributable build.

Or via command line:

```sh
xcodebuild -scheme EMJC -configuration Release \
  -archivePath build/EMJC.xcarchive archive
xcodebuild -exportArchive \
  -archivePath build/EMJC.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/
```

> For a Developer ID export, set `method` to `developer-id` in `ExportOptions.plist`.

## Install

Copy the built app to `/Applications`:

```sh
cp -R build/EMJC.app /Applications/
```

macOS registers the embedded Quick Look extension automatically. If it doesn't activate immediately, force re-registration:

```sh
pluginkit -a /Applications/EMJC.app
qlmanage -r        # reload Quick Look daemon
qlmanage -r cache  # clear thumbnail cache
```

Then rename the emoji font and select it in Finder, then press **Space**:

```sh
cp /System/Library/Fonts/Apple Color Emoji.ttc ~/Desktop/AppleColorEmoji.ettc
```

## Uninstall

```sh
rm -rf /Applications/EMJC.app
qlmanage -r
```

## Debug / logging

The extension writes diagnostic logs under the `com.ps.EMJC.QuickLook` subsystem. To stream them while previewing a file in Finder:

```sh
log stream --predicate 'subsystem == "com.ps.EMJC.QuickLook"' --level debug
```

> `qlmanage -p` cannot be used to test sandboxed extensions — use Finder's Space-bar preview only.

## Supported file types

| UTI | Extension |
|-----|-----------|
| `com.ps.emjc.emoji-ttc` (custom, exported by this app) | `.ettc` |

The custom UTI conforms to `public.truetype-collection-font`, so macOS still treats `.ettc` files as fonts. Only the EMJC Quick Look extension claims it — `.ttc` files are left entirely to the system.
