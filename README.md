# Sheaf

A PDF reader for the Mac, made for research papers, work documents and studying.
Highlights have meanings: four highlighters mark **key ideas**, **questions**,
**definitions** and **evidence**, and the library brings them together across
every PDF you read.

## Features

- **Library** of every PDF you open: files stay where they are on your Mac;
  collections, starring, reading progress, search across titles, highlights and notes,
  and the full text of every PDF (indexed in the background, shown with the page and
  the words around each match). Drop PDFs or whole folders to add them; dropped on a
  collection, they join it
- **Review**: flashcards from your highlights (Definitions to start with). The front
  shows your note, or the PDF and page; Space shows the highlight; 1 Again, 2 Got it
- **Reader** with page thumbnails, table of contents, single / two-page / scroll layouts,
  zoom, search, and your place remembered
- **Highlighting** with keys 1–4 or the toolbar, notes on each highlight, undo,
  and export to Markdown
- Highlights are saved **inside the PDF** as standard annotations (so Preview shows them)
  **and** in Sheaf's library. Password-protected and digitally signed PDFs are never rewritten.
- One window: the library, or the PDF you're reading; switch with ⌃Tab or ⇧⌘] / ⇧⌘[
- Light and Dark Mode

## Requirements

- macOS 15 Sequoia or later
- Xcode 27 or later to build

## Build and run

1. Open `Sheaf.xcodeproj` in Xcode.
2. Choose the **Sheaf** scheme and **My Mac**.
3. Press **⌘R** to run, **⌘U** to run the tests.

From the command line:

```sh
xcodebuild -project Sheaf.xcodeproj -scheme Sheaf test
```

## Installing and updates

Every push to `main` builds Sheaf on GitHub, runs the tests and publishes the app
on the repo's **Releases** page as `Sheaf.zip` (the five newest builds are kept).

Installing, once:

1. Download `Sheaf.zip` from the newest release, open it, and drag **Sheaf** into Applications.
2. The first time, macOS says it can't check Sheaf for malware, because the app isn't
   notarized by Apple. Click **Done**, open **System Settings › Privacy & Security**,
   and click **Open Anyway** next to Sheaf.

After that, Sheaf updates itself. When it opens, and every hour while it's open, it
checks the newest release; if there's a newer build it offers to install it, and
**Sheaf › Check for Updates…** checks right away. The library, highlights and notes
are kept: they live in Sheaf's own storage, not inside the app. Builds run from Xcode
never check for updates.

How it works: the app uses [Sparkle](https://sparkle-project.org). Each release also
contains `appcast.xml` (made by `Scripts/make-appcast.sh`), which describes the build
and carries an EdDSA signature of the zip. Sheaf installs a download only if that
signature matches the public key in `Info.plist` (`SUPublicEDKey`). The private key
is the repo secret `SPARKLE_PRIVATE_KEY`, with a copy in the developer's login keychain
(account `sheaf`). Without it no update can be published, so keep the keychain copy:
`generate_keys --account sheaf -x <file>` exports it again.

## Project structure

Code is organized by feature, following Apple's sample projects
(Food Truck, Backyard Birds). The `Sheaf` folder is an Xcode *synchronized folder*:
files added on disk appear in the project automatically.

```
Sheaf/
├── SheafApp.swift      App entry point: the window and its menus
├── Info.plist          Document types (PDF) and app settings
├── Sheaf.entitlements  Sandbox permissions
├── App/                Window, workspace of open PDFs, menu commands, app delegate, updater
├── Library/            Library screen: sidebar, PDF list, Highlights page, text matches, recent highlights
├── Review/             Flashcards from highlights: the deck and the Review page
├── Search/             The text index of every PDF, kept up to date in the background
├── Reader/             Reader screen: header, page strip, highlights panel, search, model
├── Highlights/         Writing highlights into PDF files (in the background)
├── Data/               SwiftData models (PDFs, collections, highlights) and the library store
├── DesignSystem/       Colors, type, wordmark, shared buttons and layouts
└── Resources/          App icon, asset catalog, Space Grotesk font
SheafTests/             Swift Testing tests; shared helpers in Support/
Scripts/                Developer scripts (app icon, update feed)
```

## Tech stack

Swift 6 · SwiftUI with some AppKit · PDFKit · SwiftData · Swift Testing.
One third-party dependency: [Sparkle](https://github.com/sparkle-project/Sparkle)
for updates, added with Swift Package Manager.

## Scripts

Regenerate the app icon images:

```sh
swift Scripts/make-app-icon.swift Sheaf/Resources/Assets.xcassets/AppIcon.appiconset
```

The icon set's `Contents.json` expects files named `icon_16.png` … `icon_1024.png`.

`Scripts/make-appcast.sh` writes the update feed for a build; the GitHub workflow
runs it, so it isn't needed by hand.

## Credits

[Space Grotesk](https://github.com/floriankarsten/space-grotesk) by Florian Karsten,
licensed under the SIL Open Font License 1.1 (`Sheaf/Resources/Fonts/SpaceGrotesk-OFL.txt`).

[Sparkle](https://github.com/sparkle-project/Sparkle), licensed under the MIT License.
