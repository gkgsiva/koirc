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
3. Open the top menu → 🔧 Tools → **Library sync**.

## Set up

* **Server address**: e.g. `https://library.gkgsiva.co.in`.
* **Sign in with**: *user name and password* (HTTP Basic, the same login as the web app) or
  *API token* (the server's `API_TOKEN`, sent as a Bearer token). Tap the line to switch.
* **Download folder**: defaults to `/mnt/us/Library` on a Kindle and `<home>/Library` elsewhere.
* **Test connection** checks the address and login.
* **Sync now** starts a sync. Tap the progress message to stop; running it again continues.
  It is also available as a gesture/button action: *Library sync: sync now*.

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
