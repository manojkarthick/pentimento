# Pentimento

Pentimento is a native macOS app for inspecting and removing metadata from photos. It shows everything embedded in an image, highlights privacy-sensitive fields such as location, and lets you strip individual tags or all of them. It checks that the image itself is unchanged before it replaces the original.

Pentimento runs on macOS 14 or later and uses a bundled copy of [ExifTool](https://exiftool.org).

## Install

With Homebrew:

```sh
brew install --cask manojkarthick/tap/pentimento
```

Or download the DMG from the [latest release](https://github.com/manojkarthick/pentimento/releases/latest) and drag Pentimento to Applications. The app isn't notarized, so Gatekeeper blocks a downloaded copy. To allow it, run:

```sh
xattr -dr com.apple.quarantine /Applications/Pentimento.app
```

The Homebrew cask does this for you.

## Features

- **Inspect.** Open photos with ⌘O or drag them into the window. For each photo, you see a preview, all its metadata, tags grouped into six privacy categories, any ExifTool warnings, and GPS coordinates. You can search and filter by group.
- **Remove selected tags.** Select individual tags and choose **Remove Selected**.
- **Remove all metadata.** **Remove All** clears supported embedded metadata. It keeps orientation and color information, so the photo looks the same.
- **Verify every edit.** Pentimento edits a temporary copy, then reads it back. It compares the decoded pixels, dimensions, orientation, color profile, and any depth, matte, and HDR gain-map data with the original. It replaces the original only if all of these checks pass. If an edit fails, the original stays as it was.
- **Recent photos.** The sidebar keeps a list of recent photos. Removing a photo from the list doesn't delete the file.
- **Private.** Inspecting and editing photos makes no network requests. The only exception is **Open in Maps**, which you choose explicitly; it sends the photo's coordinates to Apple Maps.

## Supported formats

| | Formats |
| --- | --- |
| Read | JPEG, HEIC/HEIF, PNG, TIFF, WebP, AVIF, GIF, DNG, CR2, CR3, NEF, ARW, RAF, ORF, RW2 |
| Read and write | JPEG, PNG, TIFF, HEIC, HEIF |

Support for each format depends on ExifTool. Pentimento doesn't edit RAW files or the other read-only formats.

## What Pentimento doesn't do

A successful removal means that Pentimento confirmed the tags you asked to remove are gone. It doesn't mean that the photo contains no personal information. After an edit, Pentimento shows any classified tags that remain. Metadata can also be unsupported, inside maker notes, or visible in the image itself.

Keep these limits in mind:

- **There is no undo.** Pentimento doesn't keep a backup of the original metadata. Keep a copy of a photo if you might need its metadata later.
- **Live Photos are only partly cleaned.** A Live Photo is a still image and a companion video. Pentimento cleans only the still image. It doesn't inspect or clean the video, which can contain location, dates, sound, and other identifying information. To keep the still and video paired, **Remove All** keeps Apple Maker Notes, the pairing identifier, and camera make and model. The Maker Notes can contain device IDs, capture times, and other sensitive information. Pentimento tells you when this information remains.
- **Replacing a file gives it a new identity on disk.** Aliases and other references to the original can break. Pentimento refuses to edit hard-linked files and symlinks.
- **An interrupted edit can leave a working copy.** If the Mac crashes or loses power during an edit, a hidden `.pentimento-<UUID>.<ext>` file can remain next to the photo. It contains the original metadata. You can delete it when no edit is running.
- **Validation covers what Image I/O can read.** Image formats or auxiliary data that macOS Image I/O doesn't expose aren't compared.

## Build from source

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project and the bundled ExifTool aren't checked in. To download ExifTool and generate the project, run:

```sh
make generate
```

Then open `Pentimento.xcodeproj`, select the **Pentimento** scheme, and run it. Or use `make`:

```sh
make help      # list the commands
make build     # Release build (runs generate first)
make test      # Debug build and XCTest suite
make run       # build, then open the app
make dist      # build, then copy the app to dist/Pentimento.app
make release VERSION=0.1.0  # ad-hoc signed dist/Pentimento-0.1.0.dmg
make clean     # delete build and dist output
```

The built app is at `build/Build/Products/Release/Pentimento.app`. It isn't signed. `make release` signs it ad hoc and puts it in a DMG.

The tests use only generated images. They never edit your photos.

## Releasing

The **Release** workflow makes releases from the tip of `main`. To start it, go to **Actions → Release → Run workflow**:

- **channel**: `stable` releases the next version. `beta` releases the next `-beta.N` pre-release.
- **bump**: the part of the last stable version to increment (`patch`, `minor`, or `major`).

The workflow generates release notes from Conventional Commit messages with [git-cliff](https://git-cliff.org) and adds them to `CHANGELOG.md`. It then tags the release, runs the tests, and attaches a universal DMG to a GitHub Release. A stable release also updates the Homebrew cask. This step needs a `HOMEBREW_TAP_TOKEN` secret: a fine-grained token with read and write access to the contents of the tap repository.

## ExifTool

Pentimento bundles ExifTool 13.59 and runs it with the system Perl at `/usr/bin/perl`. If that isn't available, it falls back to an ExifTool installed by Homebrew. To upgrade ExifTool, change `VERSION` and `SHA256` in `script/fetch_exiftool.sh`.

ExifTool is copyright 2003–2026 Phil Harvey. You can redistribute it under the same terms as Perl (the Artistic License or the GPL).
