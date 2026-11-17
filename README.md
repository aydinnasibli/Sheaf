# Sheaf

A PDF reader for the Mac, made for research papers, work documents and studying.
Highlights have meanings: four highlighters mark **key ideas**, **questions**,
**definitions** and **evidence**, and the library brings them together across
every PDF you read.

## Features

- **Library** of every PDF you open: files stay where they are on your Mac;
  collections, starring, reading progress, search across titles, highlights and notes
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

## Project structure

Code is organized by feature, following Apple's sample projects
(Food Truck, Backyard Birds). The `Sheaf` folder is an Xcode *synchronized folder*:
files added on disk appear in the project automatically.

```
Sheaf/
├── SheafApp.swift      App entry point: the window and its menus
├── Info.plist          Document types (PDF) and app settings
├── Sheaf.entitlements  Sandbox permissions
├── App/                Window, workspace of open PDFs, menu commands, app delegate
├── Library/            Library screen: sidebar, PDF list, Highlights page, recent highlights
├── Reader/             Reader screen: header, page strip, highlights panel, search, model
├── Highlights/         Writing highlights into PDF files (in the background)
├── Data/               SwiftData models (PDFs, collections, highlights) and the library store
├── DesignSystem/       Colors, type, wordmark, shared buttons and layouts
└── Resources/          App icon, asset catalog, Space Grotesk font
SheafTests/             Swift Testing tests; shared helpers in Support/
Scripts/                Developer scripts (regenerating the app icon)
```

## Tech stack

Swift 6 · SwiftUI with some AppKit · PDFKit · SwiftData · Swift Testing.
No third-party code dependencies.

## Scripts

Regenerate the app icon images:

```sh
swift Scripts/make-app-icon.swift Sheaf/Resources/Assets.xcassets/AppIcon.appiconset
```

The icon set's `Contents.json` expects files named `icon_16.png` … `icon_1024.png`.

## Credits

[Space Grotesk](https://github.com/floriankarsten/space-grotesk) by Florian Karsten,
licensed under the SIL Open Font License 1.1 (`Sheaf/Resources/Fonts/SpaceGrotesk-OFL.txt`).
