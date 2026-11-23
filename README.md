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

* Tap a book: if it is on the device it opens. Otherwise it offers to download just that book now
  (besides *Search → Server*, the only time browsing goes online) into its own Library folder, or to
  put it on the *Read later* list for the next sync.
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
* **Test connection** checks the server step by step and says in plain words what it found: whether
  the address answers, whether the sign-in works, the catalog's name, the account, the Library's version
  (from `/api/v1`) and which of the plugin's features this server supports (reading progress, status and
  ratings, highlights and notes, next in series, search), naming what is missing and the version that
  adds it. It also shows the battery and whether automatic syncs are allowed right now.
  The check runs in a background process, so a problem on the network cannot freeze or crash KOReader.
* **Save debug log** writes `librarysync-debug.txt` to the Library folder (or the `koreader` folder if
  that does not exist) and shows the exact path. It holds the plugin's recent log (written to
  `koreader/settings/librarysync_debug.log` line by line, so it survives a crash), the end of KOReader's
  `crash.log`, the plugin version, the device and the settings with passwords and tokens hidden.
* **Sync now** (settings menu or the *Sync everything now* line in the Library) starts a sync in the
  background, so you can keep reading. **Sync status** in the settings opens a small window with the
  running sync: books done and still to go, MB downloaded of the total, the book being downloaded, speed
  and time left, updated every few seconds. It opens by itself when you start a sync (turn off **Show
  progress when a sync starts** if you prefer not); **Hide** closes it and the sync carries on, **Stop sync**
  stops it. Before it downloads anything, a sync you start shows how many books, their size and about
  how long it will take, with **Start** and **Cancel** (setting **Ask before downloading**). The gesture action *Library sync: show sync status* opens it too. **Stop the running sync**
  stops it from the menu; running it again continues. A message reports the result when it ends, with
  the size downloaded, the time it took and the average speed.
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
* **Folders to sync (everything, unread only, newest N)**: tap a folder to step through its rule:
  *Everything* (the default, also for new folders), *Unread only* (books not finished), *Newest 5 / 10 /
  25* (the books added to the folder last) or *Off*. Folders that are off still show in the Library
  (marked *not synced*), books already downloaded stay, and *Download everything in this folder* still
  works for them. Books that fall out of a *Newest N* folder and were never opened are offered for
  removal in the sync preview.
* **Preview before syncing** (*10, 25 or 50 or more books*, *always* or *off*; default 10): before a
  big sync, a list shows each book that will download (size and folder) and each book that will be
  removed (gone from the server, or past the newest N), with the totals. Untick what you want to
  leave out, then **Start**. Unticked downloads are remembered and left out of later syncs (shown
  unticked in the next preview; *Forget unticked books* brings them back); unticked removals are not
  offered again. Books are only ever removed from a preview you confirmed. An automatic sync that
  needs a preview stops and leaves a note instead.
* **Resume and retry downloads when Wi-Fi connects** (on): downloads cut off (Wi-Fi lost, the device
  slept, KOReader closed) and failed ones are picked up in the background the next time Wi-Fi
  connects, at most every 10 minutes, resuming `.part` files. A book is retried 5 times this way;
  every full sync tries again.
* **Last sync · show the sync log** (also *Sync log* in the Library): the last 10 syncs, each with
  what was added, removed and could not be downloaded, and why.
* **Read later**: tap a book that is not on the device and choose *Read later*. It is saved on the
  device (works offline) and the next sync downloads it, whatever the folder rules. The Library's
  *Read later* list shows them (⏳ in the lists).
* **Get reading progress from the Library** (on): at each sync, the place reached on other devices
  (the web reader, a phone) is fetched for the books on this one (`GET /api/downloads/<id>/position`,
  only for books read since the last look, per the catalog's last-read time). When you open such a
  book and that place is newer than the one saved here, it asks to go there. **Go to a place read
  elsewhere**: *ask*, *always* or *never*. Accounts limited to OPDS get the per-book progress from the
  catalog instead.
* **KOReader collections from the Library**: *off*, *shelves* (lists, collections and your own
  folders), *series*, or *shelves and series*. Each becomes a KOReader collection with the books on the
  device, updated after each sync (and with *Update KOReader collections now*). Read them in KOReader's
  Collections (in ZenOS: the Collections tab). Books you add to these collections yourself are kept;
  collections you made are never touched.
* **Remove books deleted on the server**: lists the books this plugin downloaded that the server no
  longer has in that place (removed from the server or from that folder, as of the last sync) and
  deletes them after you confirm. Files you added yourself are never touched.
* **Send reading progress to the Library** (on by default): while you read a synced book, its place is
  saved on the device; the next sync sends it to the server (`PUT /api/downloads/<id>/position`), which
  passes it on to Hardcover. Nothing goes online while you read.
* **Long-press a book** in the Library for its details (authors, series, folders, file, summary) with
  *Open*, or *Download* and *Read later*.
* **Search**: *On device* searches the saved catalog (offline). *Server* asks the Library server
  itself (`/opds/search`, title, author, series, folder or tag), so books added since the last sync are
  found too; tap a result to download it or put it on *Read later*.

## Reading status, ratings and notes

* **Reading status** (*Send reading status and ratings*, on): *Currently reading*, *Finished* and *Did not
  finish* go to the Library at each sync (and right away when you close a book, see below). Set them with
  KOReader's own book status (file browser or the end-of-book screen), *Library: mark this book as
  finished*, or *Library: this book → Did not finish* in the reader's Tools menu. KOReader has no "did not
  finish" status, so such a book shows as *On hold* in KOReader. *On hold* set in KOReader itself stays on
  the device (the Library has no such status).
* **Get reading status from the Library** (on): statuses and ratings set on other devices, in the web app or
  on Hardcover (the catalog's `library:reading_status` and `library:my_rating`, or `library:status` on an older
  server) are written to KOReader's book status and rating after each sync, so the shelves match across
  devices. Half-star ratings show as the nearest whole star. A status or rating changed here and not sent yet
  wins.
* **Ratings and reviews**: *Library: this book → Rate this book* (1 to 5 ★), or KOReader's own rating and
  review in the book status screen. The rating is sent with the status; the review stays on the device
  (the Library has no place for it yet).
* **Send highlights and notes** (on): new highlights with their notes go to the Library's *Notes* page
  (`POST /api/downloads/<id>/highlights`), edited notes are updated (`PATCH /api/highlights/<id>`).
  Highlights deleted here stay on the server.
* **Send progress when a book is closed** (on): closing a synced book while Wi-Fi is on sends its place,
  status, rating and notes at once in the background (a few seconds, nothing on screen). Without Wi-Fi it
  all waits for the next sync. Wi-Fi is never turned on for it.

The status and rating use `PUT /api/downloads/<id>/status` with only what changed (`{"status": "reading" |
"finished" | "dnf", "rating": 0.5-5, "finished_at": "<ISO 8601>"}`); once the server answers, they are taken
off the queue, and on a failed sync they stay queued for the next one. A Library server older than that call
still gets *Finished* and *Currently reading* through the reading position; *Did not finish* and ratings are
kept on the device and sent once the server is updated (the sync summary says so).

## Finished books and storage

* **Storage budget** (*off*, 1, 2, 4, 8 or 16 GB): when a download would take the Library past it, the sync
  first removes the books you finished longest ago, until it fits. If nothing more can be removed, the sync
  pauses and says so.
* **Remove finished books after** (*off*, 1, 7, 14, 30 or 90 days): each sync removes the books finished at
  least that long ago.
* Both are off until you turn them on, and turning one on asks first. Only the book files are deleted:
  KOReader's reading data, highlights and notes stay. Books being re-read, on *Read later*, open, or brought
  back are never removed by themselves. Finished = *Finished* on this device, or read to the end on the
  Library and not re-started here.
* **Removed books** (Library list, and in the settings): every book removed this way, newest first. Tap one
  to *Download again now*, *Get it back at the next sync* (into the same place, so it continues where you
  were), or take it off the list. Removed books are not downloaded again by later syncs until you bring them
  back (or download them yourself).

## Formats, covers and series

* **Preferred format** (EPUB by default; KEPUB, AZW3, MOBI, PDF or *all formats*): when the Library has a
  book in several formats, only that one is downloaded (or the first of EPUB, KEPUB, AZW3, MOBI, PDF it has).
  **Format per folder** sets it for single folders (tap to step through). Files of other formats downloaded
  before stay.
* **Keep covers and book info up to date** (on): after each sync the books on the device get the Library's
  cover, title, authors, series and description as KOReader's custom book info (shown in the file browser,
  the cover browser and Book information) whenever they change, without downloading the books again; at most
  100 books per sync. **Refresh all covers and book info now** redoes it for every book.
* **Next in series** (*ask*, *add to Read later* or *off*): when you finish a book (end of the book, or
  *mark as finished*), the next one of its series is offered: *Open* when it is on the device, *Download now*
  or *Read later* when it is in the Library, or, when the Library does not have it, the next sync asks the
  Library for it (`GET /api/downloads/<id>/next`, then `POST …/next/queue` to have the Library look for it)
  and puts it on *Read later* once it is there. Also in the reader: *Library: this book → Next in series*.

## Goals, stats, battery and tidying up (v2.5)

* **Reading goals** (*Goals and reading stats*): books to finish this year and each month. The Library
  screen then starts with a line like `🎯 2026: 12 of 30 books (2 ahead) · November: 1 of 3` (tap it for the
  goal settings). Finished books count by the day they were finished: KOReader's *Finished* status, *mark as
  finished*, or a bulk *Mark as finished*.
* **Battery and charger rules** (*Battery, Wi-Fi and data*): **Automatic syncs only while charging** (off by
  default) and **Hold automatic syncs below battery** (off, 10, 20, 30 or 50 %; default 20 %; charging always
  allows them). They hold the automatic syncs (on Wi-Fi, once a day, on resume) and the Wi-Fi retries, and
  *Sync status* says why a sync is on hold. **Ignore battery and charger rules (sync anyway)** is the override
  switch: with it on, automatic syncs run whatever the battery and charger say. **Sync now** (and *Quick
  sync*, *Download everything in this folder*, single downloads) always runs, whatever these rules say.
  Sending your place when a book closes takes a few seconds and is not held.
* **Bandwidth-friendly mode** (*off*, *covers first, big books last*, *big books only on trusted Wi-Fi*):
  each sync first updates the covers and book info of the books on the device, then downloads the books
  smallest first (books on *Read later* first of all). In the trusted mode, books over **Big books** (10, 25,
  50 or 100 MB; default 25) wait until the device is on a **trusted Wi-Fi** network (*add or remove this
  network* adds the one you are on); the summary and the sync log count the books waiting. Read later books
  and single downloads always go. If the device cannot tell the network's name, no network counts as
  trusted: use *covers first, big books last* then.
* **New on this device** (Library list, settings, gesture *Library: new on this device*): the books recent
  syncs and downloads brought in, newest first (the last 100), each with the time it arrived. Tap one to open
  it; books moved or removed since are marked.
* **Reading stats** (Library list with today's pages and time, gesture *Library: reading stats*): pages and
  reading time today, for each of the last 7 days and per week (Monday to Sunday). A page counts at each page
  turn, with the time spent on the page before (up to 5 minutes; longer is a break, and time asleep never
  counts). Kept on this device only: the Library server has no call that takes reading stats, so nothing is
  sent. *Keep reading stats* turns it off; *Clear stats* empties it.
* **Find duplicates on this device**: the same book in two folders or in two formats (by the title in the file
  name, ignoring the series prefix and format). Tap one, pick the copy to keep (★ suggests the one you read
  here, else your preferred format); the others are deleted (reading data stays) and later syncs do not
  download them again. *Keep all* hides a pair that is not really the same book.
* **Select several books** (top of any book list in the Library): tap books to tick them (*Tick all in this
  list* ticks the whole list, Back or *Cancel selection* ends it), then *Do with N ticked books*:
  * **Mark as finished**: KOReader's *Finished* status for the copies here, and *Finished* for the Library at
    the next sync (also for books not on the device).
  * **Move to a folder…**: moves the copies here into a folder you pick, with their reading data (and, where KOReader allows it, history and
    collections). Later syncs leave them there and do not download them again, reading progress keeps syncing,
    and *Remove books deleted on the server* never offers them.
  * **Remove from this device**: deletes every copy of those books here, after a question. They go on
    *Removed books* (to bring back) and later syncs do not download them again.
  * **Read later**: the ticked books not on the device download at the next sync.

## How syncing works

* Walks `/opds` → **Folders** → each folder (all pages) and downloads each book file into
  `<download folder>/<folder name>/<file name>`. A book in several folders is downloaded once and copied.
* **One format per book** (see *Preferred format*), unless *all formats* is chosen.
* **Incremental**: files already present with the exact size (from the link's `length` attribute) are skipped, and finished downloads are checked against it. A file you deleted
  on the device is fetched again on the next sync.
* **Failures and resume**: downloads go to `<file>.part`. A failed or stopped download is kept and
  resumed with an HTTP `Range` request (the Library server honours `Range`; if some other server answers with the whole file, the
  download restarts, still correct). A failed book never stops the others and is retried next time.
* The plugin never deletes anything by itself: books removed from the server stay on the device until
  you confirm their removal in a sync preview or with *Remove books deleted on the server*. The only
  exception is the opt-in *Storage budget* and *Remove finished books after*, which you confirm when turning
  them on and which list every removed book under *Removed books* to bring back.
* **Series**: if the OPDS entry carries `calibre:series` / `calibre:series_index` (or, as a fallback, a `Series: <name> #<n>` category), the file is saved as `<Series> #<n> - <file name>` (e.g. `Dune Saga #1 - Dune.epub`), so a series sorts together. Turn it off with *Put series in file names*.
* Folder and file names are made safe for the Kindle file system (`/ \ : * ? " < > |` become `_`).

## Test it

```
sudo apt-get install luajit lua-socket python3
luajit spec/run.lua
```

The specs run the sync against a fake OPDS server (`spec/server.py`) with Basic and Bearer auth,
paging, a failing file, resume with and without `Range` support, cancelling, folder rules, the sync
preview, retry, the sync log, progress pulled from the server, read later, collections, and (v2.3) reading
status both ways, ratings, highlights and notes, the push on close, next in series, removal after N days and
the storage budget with the undo list, formats, covers and book info, an older server without the status call,
and (v2.4) the status queue against the Library's status call (only changed fields, half-star ratings, gone books,
refused and failed sends) and ratings read back from the catalog, and (v2.5) reading goals, the battery and charger
rules with their override, bandwidth-friendly ordering and trusted Wi-Fi, duplicates, moved books, the new-on-this-device
list, reading stats and the health check (against a current and an older server, a refused login and no server).
`luajit spec/ui.lua` drives the screens with stubbed KOReader widgets.
In KOReader: set the server, **Test connection**, **Sync now**, then check the
file browser for the `Library` folder. Run **Sync now** a second time: it should report everything as
"Already there".
