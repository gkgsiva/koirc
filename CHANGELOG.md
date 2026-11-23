# Changelog

## v2.6 (2026-11-23)

* Fixed: a second page bar ("2 / 2" under the list's own) and a shorter list in Library sync settings and
  the plugin's other lists on ZenOS. ZenOS takes any unnamed full-screen list for its Collections view and
  makes it shorter to leave room for its tab bar, so the file browser's page bar showed underneath. The
  plugin's lists now have their own names. Settings also get one clean (flashing) refresh when they open,
  so text from the screen before does not ghost through.
* New: sync progress. **Sync status** opens a window with books done and still to go, MB downloaded of the
  total, the book being downloaded, speed and time left. It updates every 4 seconds (only the text box,
  gentle on e-ink), opens by itself when you start a sync (setting **Show progress when a sync starts**),
  has **Stop sync** and **Hide**, and works for background syncs. New gesture action *Library sync: show
  sync status*. The on-screen sync (background off) shows the same details.
* The end-of-sync summary now gives the size downloaded, how long it took and the average speed.

## v2.5.3 (2026-11-23)

* Fixed: every `https://` server address failed ("not connecting"). The plugin asked LuaSec to follow
  redirects, which LuaSec refuses outright ("redirect not supported"). Requests now go through KOReader's
  LuaSocket, which handles https and redirects, with LuaSec (no redirects) only as a fallback.
* Test connection now says which step failed: name lookup, secure connection, time-out, refused, no
  network, or a redirect it could not follow, plus the raw error.

## v2.5.2 (2026-11-23)

* Fixed: KOReader crashed on start (and on *Test connection*, *Sync now* and other actions) with
  "attempt to call method 'path' (a string value)". KOReader's plugin loader sets `path` (the plugin's
  folder) on every plugin, which replaced the plugin's own `path()` helper. The helper is now `dataPath()`.
  The UI test now sets `path` the way KOReader does, so this cannot come back unnoticed.

## v2.5.1 (2026-11-23)

* Fixed: *Test connection* could crash KOReader (seen on ZenOS). Its "Checking…" message was closed
  twice (it had a zero timeout and was closed again by hand), the network check ran on KOReader's own
  thread, and parts of the result screen were not protected. The check now runs in a background process
  with a 2-minute limit, the message is closed once, and every step is guarded.
* New: *Save debug log* (Library sync settings) writes `librarysync-debug.txt` to the Library folder with
  the plugin's log, the end of KOReader's crash.log, the version and the settings (passwords and tokens
  hidden), and shows the path. The plugin now keeps a log file as it goes, so it survives a crash.

## v2.5 (2026-11-23)

* Reading goals: books to finish this year and each month, with a progress line at the top of the Library.
* Battery and charger rules for automatic syncs: only while charging, and/or not below a battery level
  (default 20 %). Override switch *Ignore battery and charger rules (sync anyway)*. *Sync now* always runs.
* Bandwidth-friendly mode: covers and book info first, then books smallest first; optionally big books only
  on trusted Wi-Fi networks.
* Find duplicates on this device (two folders or two formats) and keep one; the others are not downloaded again.
* New on this device: what recent syncs brought in, newest first, one tap to open.
* Test connection is now a health check: reachability, sign-in, catalog, account, server version and the
  features this server supports or lacks, in plain words.
* Reading stats: pages and reading time per day and per week, kept on the device (the Library has no
  endpoint for them).
* Select several books in the Library: mark as finished, move to a folder, remove from the device, or
  put on Read later.

## v2.4 (2026-11-22)

* Did not finish and ratings sent to the Library (`PUT /api/downloads/<id>/status`), and read back from the catalog.

## v2.3 (2026-11-22)

* Reading status both ways, ratings, highlights and notes, push on book close, storage budget and
  auto-remove with undo, format per folder, covers and book info, next in series.

## v2.2 (2026-11-22)

* Two-way progress, server search, per-folder rules, sync preview, Wi-Fi retry and resume, sync log,
  shelves and series as KOReader collections, read later.

## v2.1 (2026-11-21)

* Offline browsing, background and automatic sync, folders to sync, cleanup, reading progress.

## v2.0 (2026-11-21)

* The plugin became librarysync.koplugin, an OPDS sync client for the Library server.
