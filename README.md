# Sheaf

A PDF reader for the Mac, made for research papers, work documents and studying.
Highlights have meanings: four highlighters mark **key ideas**, **questions**,
**definitions** and **evidence**, and the library brings them together across
every PDF you read.

## Features

- **Library** of every PDF you open: files stay where they are on your Mac;
  collections, starring, reading progress, and search (⌘K) across titles, highlights,
  notes and answers, and the full text of every PDF (indexed in the background, scanned
  pages too once they've been read, shown with the printed page and the words around
  each match). Drop PDFs or whole folders to add them; dropped on a collection, they
  join it. A PDF in iCloud Drive that isn't downloaded yet says so, and downloads when
  opened
- The library's list works like Finder's: select several PDFs to open, star, file,
  rename or remove them (removing asks first, and ⌘Z brings them back with everything
  made in them), Space for Quick Look, and drag PDFs out to Finder or Mail, or onto a
  collection. New Collection asks for a name; deleting one asks first and can be undone
- Fits **half a laptop screen**: the page keeps at least 480 pt, so in a narrower
  window the side panels open over the page, and the header drops or shortens controls
  rather than hiding them in an overflow menu
- **Highlights page** for revising: all PDFs, a collection or one PDF; newest first or
  in reading order, optionally grouped by PDF; by color and by open or answered
  questions. Edit, answer, recolor or delete right on the cards (⌘Z undoes), and
  export exactly what's shown as Markdown, in the same order and groups
- **Answering questions**: mark a Question highlight answered, with what you found out;
  "Open questions" only counts the ones still open. Answers stay in Sheaf's library
- **Review** (⇧⌘R): flashcards from your highlights (Definitions to start with). The
  front shows your note, or the PDF and page; Space shows the highlight; 1 Again, 2 Got it
- **Reader** with page thumbnails, table of contents, single / two-page / scroll layouts,
  zoom, search, bookmarks, Back and Forward after jumps, printing, focus mode, dark
  pages, and your place remembered
- **Highlighting** with keys 1–4 or the toolbar, undo, and export to Markdown. Esc or
  ⌘. puts the highlighter down. Click a highlight on the page to write its note, change
  its color, copy it or delete it
- **Scanned PDFs**: drag a box to highlight an area (or Option-drag off text on any
  page); Sheaf reads the words in the box, and the text of scanned pages in the
  background, so search finds them
- **Notes and citations**: notes on highlights and on whole pages, a summary of each PDF,
  the page numbers printed in the PDF (xii, 245), and Copy as Quote (⇧⌘C):
  “the text” (Title, p. 245). Page notes and summaries are kept in Sheaf's library, not
  in the file. The Edit menu checks spelling and makes smart quotes while you write
- **Spotlight** finds your highlights, page notes and summaries, and opens the PDF there
- **Honest reading progress**: a page counts as read when you read your way to it, or
  after it has been on screen a while, not when a link jumps there; a PDF is Finished
  when every page has been read
- Highlights are saved **inside the PDF** as standard annotations (so Preview shows them)
  **and** in Sheaf's library, keeping the PDF's printed page numbers, language and viewing
  settings. PDFs that rewriting could harm are never changed: password-protected, digitally
  signed or certified (Reader-extended) ones, and ones with attached files, optional layers,
  embedded media (sound, video, 3D), portfolios or XFA forms. Their highlights stay in
  Sheaf's library, and the Highlights panel says why
- One main window: the library, or the PDF you're reading; switch with ⌃Tab or ⇧⌘] / ⇧⌘[
- **Two PDFs side by side**: Open in New Window (File menu, the library's context menu,
  the reader's title menu, or ⌥-double-click) gives a PDF its own window. A PDF is in one
  window at a time; Move to Main Window puts it back, and closing its window closes it.
  The menus act on the window in front (with Help or Settings in front, they leave the
  PDFs alone), focus mode is per window, PDF windows merge into tabs (Window › Merge All
  Windows) and come back at the next launch
- **Sheaf Help** (⌘?) explains each feature and lists every keyboard shortcut;
  **Settings** (⌘,) has the reading defaults
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
├── SheafApp.swift      App entry point: the windows and their menus
├── Info.plist          Document types (PDF) and app settings
├── Sheaf.entitlements  Sandbox permissions
├── App/                Main and PDF windows, workspace of open PDFs, menu commands, PDF and
│                       highlight commands and their questions, app delegate, updater
├── Library/            Library screen: sidebar, PDF list, Highlights and Notes pages, Markdown
│                       export, text matches, recent highlights
├── Reader/             Reader screen: header, page strip, Highlights panel, notes, popovers,
│                       search, scanned pages and reading their text, model
├── Review/             Flashcards from highlights: the deck and the Review page
├── Search/             The text index of every PDF, kept up to date in the background
├── Spotlight/          Highlights, page notes and summaries in Spotlight
├── Highlights/         Writing highlights into PDF files safely, in the background, and reading
│                       the ones other apps made
├── Data/               SwiftData models (PDFs, collections, highlights, page notes), the library
│                       store, backups and citations
├── Help/               The Help window and its table of keyboard shortcuts
├── Settings/           Sheaf › Settings: reading defaults
├── DesignSystem/       Colors, type, wordmark, shared buttons, the library's page frame, panels
│                       over the page
└── Resources/          App icon, asset catalog, Space Grotesk font, credits
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
