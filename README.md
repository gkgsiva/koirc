# KOReader Library sync

A [KOReader](https://github.com/koreader/koreader) plugin that mirrors your
[Library](https://github.com/gkgsiva/library) server onto the e-reader. It reads
the server's OPDS catalog and downloads every book into a matching folder.

```
Library/                 <- /mnt/us/Library on a Kindle (changeable)
├── Dune Series/         <- one folder per Library folder (series, Hardcover list, your own)
│   └── Dune.epub
└── Reads 2026/
    └── Emma.epub
```

The plugin no longer talks to Hardcover or IRC: Hardcover is managed in the
Library web app, and the plugin only syncs what the server already holds.

## Install

1. Copy the `librarysync.koplugin` folder into KOReader's `plugins/` folder
   (`koreader/plugins/librarysync.koplugin`; on a Kindle that is `/mnt/us/koreader/plugins/`).
   Or unzip the release asset `librarysync.koplugin-vX.Y.zip` there.
2. Restart KOReader. (Remove the old `ircbooks.koplugin` folder if you had it.)
3. Open the top menu → 🔧 Tools → **Library** (settings are under **Library sync settings**).

## Browse (main entry)

Tools → **Library** opens the catalog as a browsable list. It is built from the copy of the catalog
that the last sync saved on the device, so browsing works offline and never contacts the server:
Search, Recently added, Continue reading, All books, Folders, Series and Authors, then the books.
Books show `Series #n – Title`, and ✓ marks books already on the device. Each sync refreshes the copy
(the list's subtitle shows when that was).

* Tap a book: if it is on the device it opens. Otherwise it asks whether to download just that book
  (the only time browsing goes online) into its own Library folder, and offers to open it.
* In a folder: **Download everything in this folder** syncs just that folder.
* At the top level: **Sync everything now** and **Settings**.
* Gesture/button actions: *Library: browse* and *Library sync: sync now*.
* **Open the Library when KOReader starts** (in the settings): the catalog opens over the file browser,
  once per KOReader launch.

**KOReader's own home screen:** KOReader has no plugin API to replace the file browser (its start page
choices are built in). The plugin can only open the Library over it at launch, or be placed on a gesture,
a ZenOS launcher button or a navbar tab. Closing the Library returns to the normal file browser, where the
synced `Library` folder is also available offline.

## Set up

* **Server address**: e.g. `https://library.gkgsiva.co.in`.
* **Sign in with**: *user name and password* (HTTP Basic, the same login as the web app) or
  *API token* (the server's `API_TOKEN`, sent as a Bearer token). Tap the line to switch.
* **Download folder**: defaults to `/mnt/us/Library` on a Kindle and `<home>/Library` elsewhere.
* **Test connection** checks the address and login.
* **Sync now** (settings menu or the *Sync everything now* line in the Library) starts a sync in the
  background, so you can keep reading. **Sync status** in the settings shows what it is doing and
  **Stop the running sync** stops it; running it again continues. A message reports the result when it ends.
  Turn off **Sync in the background** to run it on screen with a "tap to stop" message instead.
  It is also available as a gesture/button action: *Library sync: sync now*.

## More settings

* **Quick sync (only new books)**: asks only for the books added since the last sync (the top of
  *Recently added*), so it finishes in a few seconds. A full sync now and then still catches books
  moved between folders or removed from the server.
* **Sync automatically**: *off*, *when Wi-Fi connects* (a quick sync, at most once an hour) or *once a
  day* (a full sync when Wi-Fi is on and the last sync is a day old). It runs in the background, only
  shows a short note when books arrive, and never turns Wi-Fi on by itself.
* **Storage**: the settings show how much the Library takes and what is free. **Keep free at least**
  (50 MB to 1 GB, default 100 MB): a sync pauses before a download would go below it.
* **Mark as finished**: *Library: mark this book as finished* in the reader's Tools menu, or KOReader's
  own "finished" status (also set from the file browser). The next sync sends the book as 100% read to
  the Library, which tells Hardcover.
* **Folders to sync**: tick the Library folders that a sync downloads. All are on by default, and
  new folders are synced. Unticked folders still show in the Library (marked *not synced*), books
  already downloaded stay, and *Download everything in this folder* still works for them.
* **Remove books deleted on the server**: lists the books this plugin downloaded that the server no
  longer has in that place (removed from the server or from that folder, as of the last sync) and
  deletes them after you confirm. Files you added yourself are never touched.
* **Send reading progress to the Library** (on by default): while you read a synced book, its place is
  saved on the device; the next sync sends it to the server (`PUT /api/downloads/<id>/position`), which
  passes it on to Hardcover. Nothing goes online while you read.
* **Long-press a book** in the Library for its details (authors, series, folders, file, summary) with
  *Open* or *Download*.

## How syncing works

* Walks `/opds` → **Folders** → each folder (all pages) and downloads each book file into
  `<download folder>/<folder name>/<file name>`. A book in several folders is downloaded once and copied.
* **Incremental**: files already present with the exact size (from the link's `length` attribute) are skipped, and finished downloads are checked against it. A file you deleted
  on the device is fetched again on the next sync.
* **Failures and resume**: downloads go to `<file>.part`. A failed or stopped download is kept and
  resumed with an HTTP `Range` request (the Library server honours `Range`; if some other server answers with the whole file, the
  download restarts, still correct). A failed book never stops the others and is retried next time.
* The plugin never deletes anything: books removed from the server, or folders renamed, stay on the device.
* **Series**: if the OPDS entry carries `calibre:series` / `calibre:series_index` (or, as a fallback, a `Series: <name> #<n>` category), the file is saved as `<Series> #<n> - <file name>` (e.g. `Dune Saga #1 - Dune.epub`), so a series sorts together. Turn it off with *Put series in file names*.
* Folder and file names are made safe for the Kindle file system (`/ \ : * ? " < > |` become `_`).

## Test it

```
sudo apt-get install luajit lua-socket python3
luajit spec/run.lua
```

The specs run the sync against a fake OPDS server (`spec/server.py`) with Basic and Bearer auth,
paging, a failing file, resume with and without `Range` support, and cancelling.
In KOReader: set the server, **Test connection**, **Sync now**, then check the
file browser for the `Library` folder. Run **Sync now** a second time: it should report everything as
"Already there".
