# KOReader IRC book search

A [KOReader](https://github.com/koreader/koreader) plugin that searches IRC ebook
channels (such as `#ebooks` on IRCHighway) and downloads books straight to your
e-reader.

**Flow:** search → list of results → tap a book → it is downloaded into your
download folder and you can open it right away.

## Install

1. Copy the `ircbooks.koplugin` folder into KOReader's `plugins/` folder
   (for example `koreader/plugins/ircbooks.koplugin` on a Kobo or Kindle).
2. Restart KOReader.
3. Open the top menu → 🔍 (search tab) → **IRC book search**.

### ZenOS / Zen UI, gestures and launchers

Zen Mode in ZenOS hides KOReader's regular menu tabs. The plugin also
registers two actions you can put on a button or gesture:

* **IRC book search**: opens the search box (which also has a **Settings** button)
* **IRC book search settings**
* **IRC book search: Hardcover lists**

The search box also has a **Hardcover lists** button, so the existing search
action is enough to reach your lists.

In ZenOS, add one of them to a Launcher button, a Navbar tab or a Controls
button (pick it from the list of actions; it is in the General section). In
plain KOReader, use Settings → Taps and gestures → Gesture manager. Turning
Zen Mode off also brings back the regular menus.

## Use

* **Search for a book…** asks for an author and/or title. The plugin turns on
  Wi‑Fi if needed, connects, joins the channel and sends `@search <your text>`.
* The search bot sends back a results file. The plugin unpacks it and shows one
  line per book with its size and the bot that has it.
* On the results screen, tap the first line (or the ☰ icon at the top) to
  filter by format (e.g. only `epub`, with counts per format) or to search
  within the results by title, author or bot name.
* Tap a result and confirm. The plugin sends the request line (e.g.
  `!Oatmeal Author - Title.epub`) and receives the file by DCC. If the book comes
  as a `.zip` holding a single book, it is unpacked for you.
* When the download finishes you can open the book immediately.
* Tap the progress message at any time to cancel.

The connection stays open between searches so that browsing results and
downloading is quick. It closes after 5 idle minutes, when the device
sleeps, or via **Disconnect**.

## Hardcover lists

Track what you want to read on [Hardcover](https://hardcover.app) (for example a
list per series) and fetch the books from IRC one after another.

1. Get your API key at <https://hardcover.app/account/api>.
2. Put it on the device. Typing it is tedious, so the easiest way is to save it
   in a plain text file named `hardcover.txt` in the KOReader folder (e.g.
   `koreader/hardcover.txt`) or in your home/download folder. The plugin picks
   it up automatically. You can also paste it under **Settings → Hardcover API
   key**, which has **Load from file** and **Clear** buttons. The key is stored
   in KOReader's settings on the device only.
3. Open **Hardcover lists…** (menu, search box button or the action above).
   You see **Series tracker**, your **Want to read** shelf and all your lists.
   Series tracker shows the series you follow on hardcover.app/series-tracker
   and the series of books you are reading or have read; opening one lists its
   main books (#1, #2, …) like any other list.
4. Open a list. Each book shows **✓ on device** or **✗ missing**, with the
   author and series. A book counts as on the device when it was downloaded
   through this screen, or when a book file in the download/home folder (and
   subfolders) has the title words, plus the author's surname for short titles,
   in its name. Tap a ✓ book to start reading it. Tap a ✗ book to **Attach a
   file I have…** (pick any file on the device) or **Download from IRC**. Hold
   a ✓ book for **Download again**, **Attach another file…** or **Detach file**
   (if the automatic match is wrong).
5. Tap **Download missing books one by one**, or tap a single missing book. The
   search text (author + title) is filled in for you to adjust, **Skip** to the
   next book, or choose **I already have it: attach file…**. Pick a result as usual.
6. After the download choose **Next book** (the next missing one in the list),
   **Open**, or **Cancel**. If the search finds nothing you can change the search
   or go to the next book.

**Start KOReader in the Hardcover view** (Settings) opens your lists, and the
list or series you had open last, when KOReader starts and again when you close
a book you opened from there. Without Wi‑Fi it shows the last loaded copy,
marked "(offline)".

## Settings

Under **IRC book search → Settings**:

**Network** picks a preset, which fills in the server, channel and search
command:

* IRCHighway `#ebooks` (default) for general fiction and non-fiction
* IRCHighway `#bookz` for technical books, audiobooks and larger archives
* Undernet `#bookz` and `#ebooks` (`irc.undernet.org`)

Each value can still be edited below it, for example if a channel uses a
different search command.

| Setting | Default |
| --- | --- |
| Server | `irc.irchighway.net` |
| Port | `6667` (`6697` with TLS) |
| Use TLS | off |
| Nickname | `koreader` + 4 random digits |
| Server password | none |
| Channel | `#ebooks` |
| Search command | `@search` |
| Only show formats | all (e.g. `epub, mobi` to filter) |
| Download folder | KOReader's download/home folder |
| Hardcover API key | not set (or read from `hardcover.txt`) |

## Limitations

* Only normal (active) DCC is supported: the bot must be reachable from your
  device. Passive/reverse DCC needs an open port on the reader, which is rarely
  possible behind home routers, so those offers are reported as an error.
* `.rar` downloads are saved as-is; KOReader cannot open them.

## Development

The protocol code lives in `ircbooks.koplugin/koirc/` and has no KOReader
dependencies (only LuaJIT + LuaSocket), so it can be tested on a desktop:

```sh
sudo apt-get install luajit lua-socket python3
luajit spec/run.lua
```

The tests run a fake IRC server with search and book bots on localhost and
exercise the whole search → results → DCC download path, plus the ZIP/DEFLATE
decoder against archives produced by Python's `zipfile`.

| File | Purpose |
| --- | --- |
| `main.lua` | KOReader UI: menu, settings, search dialog, results list, downloads |
| `hardcoverui.lua` | KOReader UI for Hardcover lists and the next-book flow |
| `koirc/hardcover.lua` | Hardcover GraphQL client and matching books to local files |
| `koirc/fetcher.lua` | IRC session and search/download jobs (non-blocking state machine) |
| `koirc/conn.lua` | Non-blocking TCP/TLS connection |
| `koirc/dcc.lua` | DCC SEND receiver |
| `koirc/proto.lua` | IRC line, CTCP and DCC parsing |
| `koirc/results.lua` | Parses search bot result files |
| `koirc/unzip.lua` | Pure-Lua ZIP + DEFLATE reader |
