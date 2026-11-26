# Pentimento

A standalone SwiftUI macOS application for inspecting and removing photo metadata. The deployment target is macOS 14.

Building needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). `Pentimento.xcodeproj` and the bundled ExifTool aren't checked in: run `make generate` to download ExifTool and generate the project, then open `Pentimento.xcodeproj`, select the **Pentimento** scheme, and Run.

## Build and test

```sh
make help      # list the commands
make generate  # download ExifTool and regenerate the Xcode project from project.yml
make build     # Release build (runs generate first)
make test      # Debug build and XCTest suite
make run       # build, then open the app
make dist      # build, then copy the app to dist/Pentimento.app
make release VERSION=0.1.0  # ad-hoc signed dist/Pentimento-0.1.0.dmg
make clean     # delete build and dist output
```

Builds go to `build/`, so the app is in `build/Build/Products/Release/Pentimento.app`. `make dist` copies it to `dist/Pentimento.app`. It is unsigned; `make release` signs it ad-hoc and wraps it in a DMG.

## Releases

Releases are cut by the manual **Release** workflow (Actions → Release → Run workflow) from the tip of `main`:

- **channel** `stable` releases the next version; `beta` releases its next `-beta.N` pre-release.
- **bump** picks the part of the last stable version to increment (`patch`, `minor` or `major`). The first release is `v0.1.0`.

The workflow writes the release notes with [git-cliff](https://git-cliff.org) (`cliff.toml`) from Conventional Commit messages, commits them to `CHANGELOG.md`, tags, creates the GitHub Release, runs the tests, builds the universal DMG and attaches it. Stable releases also update the `pentimento` cask in `manojkarthick/homebrew-tap`, which needs the `HOMEBREW_TAP_TOKEN` secret (a fine-grained PAT with Contents read/write on the tap).

The app is ad-hoc signed, not notarized, so Gatekeeper blocks a downloaded copy. Install with Homebrew, whose cask clears the quarantine flag:

```sh
brew install --cask manojkarthick/tap/pentimento
```

or, after copying the app from the DMG, run `xattr -dr com.apple.quarantine /Applications/Pentimento.app`.

## App icon

`Design/AppIcon-Original.png` preserves the supplied artwork. `Design/AppIcon.png` is the transparent master used for the app. The `AppIcon` asset set contains all ten macOS 1× and 2× representations, from 16 to 1024 pixels. Xcode compiles these into the app's icon automatically; `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME` so regenerating the project preserves the configuration.

## What it does

Open multiple photos with Command+O or drag them into the window. The sidebar keeps a local recent list with security-scoped bookmarks; its context menu can reveal a file or remove it from the list. Clear the list from the File menu or Settings. The detail view shows a preview, all metadata, six privacy categories, search, group filtering, per-tag selection, warnings, and GPS coordinates. Metadata is cached in memory for the current session, and sidebar/detail requests share an in-progress read. Switching photos reuses the cache; Refresh reads the file again, and an edit replaces the cached result. Removing a photo or clearing the recent list evicts its cached metadata. Use Refresh after edits made in another application. Opening Maps is explicit and sends coordinates to Apple Maps; inspection and editing make no network requests.

Reads: JPEG, HEIC/HEIF, PNG, TIFF, WebP, AVIF, GIF, DNG, CR2, CR3, NEF, ARW, RAF, ORF, and RW2, subject to ExifTool's support for each file. Writes: **JPEG, PNG, TIFF, HEIC, and HEIF**. Proprietary RAW and all other formats are read-only. A tag shown as selectable is a candidate for removal; ExifTool and the resulting image are checked before the original changes.

**Remove Selected** asks ExifTool to clear the exact group-qualified keys selected. **Remove All** clears supported embedded metadata while restoring orientation and color information, including PNG sRGB rendering. Both operations work on a temporary copy in the photo's directory, re-read its metadata, decode all Image I/O image resources, compare pixel hashes, dimensions, orientation, color model, ICC profile bytes, and available depth/matte/HDR gain-map data and properties, and atomically replace the original only if those checks pass. Concurrent edits to the same photo are refused. A changed original is detected before replacement. Normal failures remove the temporary copy and leave the original intact. No undo or metadata backup is kept.

A green result means the **requested tag keys** were verified absent. It does not mean that all personal information was removed. The interface separately shows remaining classified tags and unclassified removable tags. ExifTool warnings are displayed. Some metadata may be unsupported, hidden in pixels, inside maker notes, or outside the inspection scope.

In the Photos sidebar, Command-click to select individual photos or Shift-click to select a range, then right-click the selection and choose **Remove Photos from List**. You can also use the selection button beside **+** to check multiple photos, optionally **Select All**, then **Remove from List**. **Done** leaves checkbox selection mode without removing anything. Removing photos from the list keeps the original files on disk.

## Performance

The distributed app uses the optimized Release configuration (`-O`, whole-module compilation, testability disabled). Sidebar images (96 pixels) and detail previews (512 pixels) are decoded on a background queue with at most two simultaneous jobs. The UI receives small materialized bitmaps, so drawing cannot defer full-resolution HEIC/HDR decoding onto the main thread. The image cache is limited to 64 MB and reuses in-progress requests; Refresh and successful edits invalidate the affected previews. The metadata list creates rows as they become visible.

A local before/after check with the same six-photo HEIC library measured approximately 1.3 GB versus 74 MB of application memory. The updated profile placed HEIC decoding on the preview queue rather than the main thread. These are observations from that session, not a fixed memory or latency guarantee. Initial previews load asynchronously; evicted previews may be decoded again.

## HEIC and Live Photos

HEIC/HEIF edits use ExifTool without re-encoding the image and follow the same temporary-copy and verification workflow. Selective removal preserves pairing identifiers and independently checks the decoded image, orientation, color and available auxiliary resources before replacement.

A Live Photo consists of a still image and a companion video. When the still image contains a pairing identifier, **Remove All preserves Apple Maker Notes, pairing identifiers, and camera make/model**. ExifTool copies the Maker Notes as a block because it cannot recreate arbitrary individual Maker Note fields. These retained notes can contain device IDs, capture times, and other sensitive information; the UI and operation result report that information remains. Pairing identifiers are protected from individual selection.

**The companion MOV is not inspected or cleaned by this app.** It may retain location, dates, sound, visible content, and other identifying information. Cleaning a HEIC is not a privacy clearance for the complete Live Photo. Pairing-identifier preservation is tested with synthetic still metadata; end-to-end Live Photo playback and Photos re-import have not been tested.

## ExifTool and licensing

The app bundles ExifTool 13.59 as its Perl script and `lib/Image/ExifTool` modules in `Pentimento/Resources/ExifTool`. `script/fetch_exiftool.sh` downloads them from the official GitHub mirror and checks a pinned SHA-256; change its `VERSION` and `SHA256` to upgrade. It runs with macOS `/usr/bin/perl` using `Process` and individual arguments; it needs no Glaze, Node, Homebrew, shell invocation, or network access. If the bundled script or system Perl is unavailable, it checks `/opt/homebrew/bin/exiftool` and `/usr/local/bin/exiftool`. The bundled `README` carries ExifTool's copyright and license notice: Copyright 2003–2026 Phil Harvey, redistributable under the same terms as Perl (Artistic License or GPL). Confirm the license obligations and sign/notarize before redistribution.

## Changes from the Glaze version

The native app has no WebView or separate settings window implementation. It uses native controls, bookmarks instead of `localStorage` path strings, and presents read/write warnings. Structural metadata, individual Maker Note fields, and Live Photo pairing identifiers are not selectable. Sensitive read-only fields are included in the detected-sensitive count and shown in All Metadata. The original app could attempt edits on RAW files and wrote directly in place; this app restricts edits to JPEG/PNG/TIFF/HEIC/HEIF and validates a temporary copy first. A successful operation reports verified requested removal, not complete privacy clearance. The native app does not preserve the original file's inode after replacement, which can affect aliases or external references; hard-linked files and symlinks are refused.

## Known limits

- Every image exposed by Image I/O is independently decoded and compared before replacement. Available depth, disparity, portrait/segmentation mattes and HDR gain maps are also checked. Private or newer auxiliary formats that Image I/O does not expose are outside this validation scope.
- Crash or power loss during an edit can leave a hidden `.pentimento-UUID.ext` working copy in the photo folder containing original metadata. Normal completion or failure removes it. Remove any such orphan after confirming no edit is running.
- HEIC tests cover generated files with Display P3, orientation, a synthetic Apple Live Photo identifier and an ISO HDR gain map. They do not establish playback or re-import compatibility for every iPhone capture variant or a complete Live Photo pair.
- The app is not sandboxed by default. This avoids losing write access to selected files; a sandboxed distribution needs entitlement and file-access validation.
- A manual UI smoke test covered launch, picker import, tag selection, removal, verification message, and removal from recents with a disposable PNG. Drag/drop and detailed layout were not covered by automated UI tests. The XCTest suite uses only generated disposable images and never edits user photographs.
