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
* **IRC book search: download history**
* **IRC book search: complete your series**
* **IRC book search: reading stats** (with your reading goal)

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
* Results are sorted with your **preferred formats** first (default
  `epub, azw3, mobi, pdf`; archives such as `.rar` go last).
* On the results screen, tap the first line (or the ☰ icon at the top) to
  filter by format (e.g. only `epub`, with counts per format), sort by format,
  size (smallest or largest first) or name, hide files above a size (2, 5, 10,
  20 or 50 MB), or search within the results by title, author or bot name.
  The sort and size choices are remembered.
* **Recent searches** (in the menu and on the search box) lists your last 15
  searches. Tap one to run it again, hold it to edit it first.
* Tap a result and confirm. Use **Change save folder…** in the confirmation to
  pick where the book goes; the folder is remembered for later downloads. To make
  a new folder, tap **New folder…** next to it (the folder goes inside the current
  save folder), or long-press any folder in the picker and choose **New folder
  here…**. The plugin sends the request line (e.g.
  `!Oatmeal Author - Title.epub`) and receives the file by DCC. If the book comes
  as a `.zip` holding a single book, it is unpacked for you.
* If you already seem to have the book (even under another file name), the
  confirmation warns you and shows where it is.
* If the bot does not send the book, the plugin tries up to two other bots
  offering the same book (in your preferred format) by itself.
* When the download finishes you can open the book immediately.
* Tap the progress message at any time to cancel.

The connection stays open between searches so that browsing results and
downloading is quick. It closes after 5 idle minutes, when the device
sleeps, or via **Disconnect**.

### First start

The first time you search, a short setup asks for the network (IRCHighway
`#ebooks` is the default), your nickname, and optionally your Hardcover API
key, and lets you **Test connection**: it connects and joins the channel
without freezing the screen, then tells you whether it worked and why not.
**Settings → Test connection** and **Run setup again…** do the same later.

### Faster searching

* The plugin starts connecting as soon as the search box opens (when Wi‑Fi is
  already on), so the search goes out the moment you tap **Search**.
* While the results file arrives, the progress message counts the results
  received so far (for plain-text results; zipped ones are counted once
  unpacked).
* The format and bot you pick in the results filter are remembered for the
  next search. If a search has nothing from them, all results are shown.
* Each result shows a badge with its format and size, e.g. `EPUB · 1.2 MB · bot`.
* Results in formats this KOReader can't open (such as `.rar` or `.djvu`
  without a reader for it) are hidden, with a count in the filter line. Turn
  this off with **Hide formats this device can't open**.
* **Hold a result** to search for more by the same author, the same series, or
  the next book in the series (from names like `Author - Series 03 - Title`).
* **Select several to download…** at the top of the results lets you tick
  books and download them all in the background, exactly the files you picked.
  To download a whole Hardcover list, use **Download missing books in the
  background** in the list.

### After a download

The finished download offers **Open**, **Add to Hardcover…** (finds the book
on Hardcover, then puts it on a shelf or in one of your lists and attaches the
file), and **Next in series** when the file name has a series number. Each
background download shows a short notice when it finishes or fails (turn off
with **Show a notice when each background download finishes**).

### When a bot is offline or a download stalls

Downloads retry by themselves with another bot that has the same book:

* A bot that is not in the channel is skipped before asking it (the plugin
  reads the channel's user list when it joins).
* A bot that says nothing for 2½ minutes, says it can't send the file, leaves
  the channel while you wait, or whose transfer stalls is given up on, and the
  next copy is tried: bots in the channel first, bots that just failed last.
* When the results have no other copy, the plugin searches again for the book
  and picks another bot from the new results.
* Up to 4 downloads are tried per book. A bot that failed is tried last for
  the next 20 minutes, also by background downloads.
* **Bot health:** the plugin remembers how often each bot sent the book, how
  long it took to start and how fast it was. Clearly more reliable bots are
  tried first. See **IRC book search → Bot health…**.

### Resuming broken downloads

When Wi-Fi drops, the device sleeps or a transfer breaks off, the part already
received is kept (as `name.epub.part` next to where the book goes). The next
try asks the same bot to continue from there (DCC RESUME), so a big file
doesn't start over. A download you started yourself continues by itself when
Wi-Fi is back; background downloads continue when you resume them. A bot that
doesn't support resuming sends the whole file again.

### Smarter ★ best match

The ★ best match leans toward the formats and bots you pick by hand: pick
mobi a few times and mobi copies move up, even if epub is first in your
preferred formats. Among equal copies, bots you use and healthy bots come
first. Turn it off in Settings (“★ best match learns…”).

### Search from a highlight

Select a title or author in a book and choose **Search IRC for books** in the
selection menu. The search box opens with the text filled in (quotes and
punctuation removed) so you can change it before searching.

### Preview

**Preview** (in a Hardcover book's dialog, in the download dialog, and when
you hold a search result) shows the book's description, page count, year and
Hardcover rating before you download it.

### Download history

**IRC book search → Download history…** lists every book you downloaded
(✓ still on the device, ✗ gone), newest first, with the date, bot and size.
Use the search icon to filter by title, author or bot. Tap a book to **Open**
it, **Download again** (asks the same bot for the same file, or another bot
when that one is gone), **Search again**, or remove it from the history. Hold
a book to download it again straight away. The last 300 downloads are kept.

### Low storage

Before a download (and before each book of a background download) the plugin
checks the free space in the download folder. When less than 100 MB would be
left, it warns and offers **Clean up finished books…**; after the cleanup it
checks again and goes on. Background downloads pause instead, and continue
when you tap them. Change the limit, or turn it off with 0, in **Settings →
Warn when less than … MB would be free**.

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
4. Open a list. Each book shows **✓** (on device) or **✗** (missing), with the
   author and series. A book counts as on the device when it was downloaded
   through this screen, or when a book file in the download/home folder (and
   subfolders) has the title words, plus the author's surname for short titles,
   in its name. Tap a ✓ book to start reading it. Tap a ✗ book to **Attach a
   file I have…** (pick any file on the device) or **Download from IRC**. Hold
   a ✓ book for **Download again**, **Attach another file…** or **Detach file**
   (if the automatic match is wrong).
5. Tap **Download missing books one by one**, or tap a single missing book. The
   search text (author + title) is filled in for you to adjust, **Skip** to the
   next book, or choose **I already have it: attach file…**. Pick a result as
   usual. The result that best matches the book's title and author (in your
   preferred format) is shown first, marked **★**.
6. After the download choose **Next book** (the next missing one in the list),
   **Open**, or **Cancel**. If the search finds nothing you can change the search
   or go to the next book.

### Background downloads

In a list with missing books, tap **Download missing books in the background…**,
tick the books you want (all missing ones are ticked) and tap **Start
downloading**. The plugin searches for each book, picks a result that matches both
the title and the author, in your preferred format (trying up to three bots if
one does not send it), and downloads it, one after another. Short notifications show the progress,
so you can keep browsing or start reading; downloads continue when you open or
close a book. At the end a summary lists what was downloaded and what was not
found. Tap the progress line in the list or in the menu to stop. If the device
sleeps or Wi‑Fi goes off, the downloads pause and you are asked whether to
continue afterwards.

Matching is forgiving about how uploaders name files: "Surname, First" or
initials for the author, accents, missing apostrophes, plurals, small typos
and spelling variants ("Colour" / "Color"), a series name or number in the
file name, a dropped subtitle, and one missing word in long titles. A result
whose author does not match is never downloaded automatically; books with no
match are listed at the end so you can search for them yourself. The same
rules choose the ★ result on the results screen.

### Matching books on the device

Books already on the reader are attached to their Hardcover entries
automatically, by file name and (with the cover browser active) by the book's
own title and author. Matches are remembered. **Refresh attached books** (on
the lists screen and at the bottom of each list) rechecks every attached file:
a file that was deleted is detached (shown ✗ again), a file that was moved or
renamed is found and re‑linked, and new matches are attached. Sync with
Hardcover does this too.

### Next book in a series

When you finish a book that belongs to a Hardcover series, the plugin offers the
next one: **Open** it if it is already on the device, or **Download** it in the
background. Turn this off with **Offer the next book in a series** in Settings.

### Reading status and progress

With **Update reading status on Hardcover** (Settings, on by default), opening a
book that is in your Hardcover lists marks it **Currently reading**, and
finishing it (reaching the end, or marking it finished in KOReader) marks it
**Read**. A book already marked Read is not moved back. Without Wi‑Fi the update
is kept and sent the next time Wi‑Fi is on or you sync.

With **Send reading progress to Hardcover** (on by default), closing the book or
putting the device to sleep sends how far you are, as pages of the Hardcover
edition (your percentage × its page count), to your current read on Hardcover.

After updating from an older version, tap **Sync with Hardcover** once so the
saved lists include series numbers, page counts and covers.

### Shelves

The lists screen shows your **Want to read**, **Currently reading**, **Paused**
and **Did not finish** shelves. To move a book between shelves, hold it in any
list and tap **Move to shelf…**, or, while reading it, use **IRC book search →
This book on Hardcover… → Move to shelf…**. A move you pick yourself is always
sent, even for a book marked Read. Opening a book you put on Did not finish
does not move it back to Currently reading; opening a paused one does.

### Rating and review

When you finish a book from your Hardcover lists, the plugin asks for a rating
(1 to 5 stars, halves too) and an optional short review, and sends both to
Hardcover. **Not now** skips it; **Don't ask again** turns the prompt off (it
is **Ask for a rating when I finish a book** in Settings). You can rate any
time from the book's hold menu in a list, or from **This book on Hardcover…**
while reading. Without Wi‑Fi the rating is sent later, like reading status.

### New releases

Each **Sync with Hardcover** also checks the series you follow (Series tracker
→ Following, up to 30) and the authors you follow on Hardcover. Books that were
not there at the previous sync show up under **New releases** at the top of the
lists screen, with the series or author they came from and the release date
(announced books too). Download them like any other list. The first sync only
records what exists, so it flags nothing. New releases stay for 60 days, or
until you tap **Clear new releases**. Turn this off with **Look for new
releases when syncing**.

### Names, folders, metadata and covers

* **Rename downloads to “Author - Title”** (Settings, off by default) names
  files after the Hardcover book (or the author and title in the IRC result).
* **Save into** puts downloads in a folder per author, per series, or author
  then series, inside the download folder. With series folders, file names get
  the series number (`Author - 03 - Title.epub`).
* **Add Hardcover title, author, series and cover to downloads** (on by
  default) gives books downloaded for a Hardcover entry its title, authors,
  series, description and cover, as KOReader's custom book metadata and cover
  (the same as Book information → Set custom metadata / cover). KOReader's file
  browser, cover view and book info then show them; the book file itself is
  not changed.

**Start KOReader in the Hardcover view** (Settings) opens your lists, and the
list or series you had open last, when KOReader starts and again when you close
a book you opened from there.

Lists, series and books are saved on the device the first time you open them,
so the screens open instantly and work without Wi‑Fi (the title says
“offline” then). When Wi‑Fi comes on, or KOReader starts, and the saved copy
is more than 6 hours old, the plugin syncs in a separate background process,
so nothing waits for Hardcover; open screens refresh when it is done. Turn this
off with **Sync with Hardcover in the background when Wi‑Fi comes on**. The
sync line shows how long ago the last sync was. Tap **Sync with
Hardcover** at the top of the lists screen to fetch the latest from Hardcover
(it shows when you last synced).

To get back to the Hardcover view at any time (for example from a book, or from
the ZenOS home screen), put the **IRC book search: Hardcover lists** action on a
ZenOS Navbar tab or Launcher button, or on a gesture (Settings → Taps and
gestures → Gesture manager). The action works in the reader too.

## Complete your series

**Hardcover lists → Complete your series** (also in the Series tracker and the
plugin menu) lists every tracked series with the volumes you don't have yet,
closest to complete first. Tap **Download all N missing volumes** to queue
them all in the background, or tap one series for just its volumes. A series
book list also has **Download all N missing volumes** at the top.

## Reading goal

The reading stats start with your yearly goal: books read, a progress bar,
and whether you are ahead or behind schedule. If you set a reading goal on
Hardcover, it is shown (loaded during a sync); otherwise use **Set yearly
goal…** on the stats screen, and books are counted when you reach the end.

## Reading stats

**IRC book search → Reading stats…** shows pages and time read per day for the
last 7 or 30 days, today's totals, the average per reading day, your streak of
days in a row, and the books you read most in that time. The numbers come from
KOReader's **Reading statistics** plugin (it must be on); nothing is sent to
Hardcover beyond the reading progress described above. The **IRC book search:
reading stats** action puts it on a gesture or a ZenOS button.

## Cleaning up finished books

**IRC book search → Clean up finished books…** lists the books on the device
that are finished: marked finished in KOReader, read to the end, or marked Read
on Hardcover by this plugin. Tap one to **Archive** it (move it to the archive
folder, `Archive` inside the download folder unless you pick another) or
**Delete** it, or use **Archive all** / **Delete all**. Reading position,
highlights and Hardcover attachments move with an archived book. The book that
is open is never listed.

## KOReader collections from Hardcover

With **Settings → Mirror Hardcover lists and series tracker as KOReader
collections** (on by default) every Hardcover list and every series in your
series tracker (followed and started, up to 60) becomes a KOReader collection
with the books of that list or series that are on the device, in list order.
Read from KOReader's own collections view, and use the Hardcover view only to
find and download books.

The collections are updated after **Sync with Hardcover** (also the background
sync), after each download and after **Refresh attached books**. A sync loads
every list and tracked series, not only the ones opened in the Hardcover view.
A book that leaves a list on Hardcover leaves the collection; a list deleted on
Hardcover removes its collection. Books you add to these collections yourself
are kept, and your other collections are never touched. Turning the setting
off removes the mirrored books again. This needs KOReader 2024.04 or newer
(named collections).

Books are found on the device by their attached file or by matching title and
author (v1.9 only used attached files, so most collections stayed empty).
Hardcover lists appear as collections even before you have one of their books;
series appear once one volume is on the device. Collections are named exactly
like the list or series on Hardcover. **Settings → Rebuild KOReader
collections now** (also a gesture/ZenOS action) scans the device and fills
them right away.

## Backup and restore

**Settings → Back up settings and library…** writes
`ircbooks-backup-YYYY-MM-DD.lua` into the download folder, with every setting
(filters, formats, folders, network, Hardcover options), the saved Hardcover
lists, attached books, mirrored collections and the download history. The
Hardcover API key and the server password are never written to it.
**Restore from a backup…** picks such a file and replaces the settings, library
and history with it; the API key and password already on the device stay.

## Debug log

**IRC book search → Save debug log** writes a text file into the download
folder with the plugin version, device, settings (without the server password
or the Hardcover API key), what the plugin did this session (IRC lines,
Hardcover errors) and the plugin's lines from KOReader's `crash.log`. Send that
file along when reporting a problem.

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
| Preferred formats, best first | `epub, azw3, mobi, pdf` |
| Sort results by | preferred format |
| Update reading status on Hardcover | on |
| Send reading progress to Hardcover | on |
| Offer the next book in a series | on |
| Add Hardcover title, author, series and cover to downloads | on |
| Ask for a rating when I finish a book | on |
| Sync with Hardcover in the background when Wi‑Fi comes on | on |
| List size | normal (compact: 14 per page; large: 6 per page, bigger tap targets) |
| Hide formats this device can't open | on |
| Show a notice when each background download finishes | on |
| Warn when less than … MB would be free | 100 MB (0 = off) |
| Mirror Hardcover lists and series tracker as KOReader collections | on |
| Look for new releases when syncing | on |
| Rename downloads to “Author - Title” | off |
| Save into | all in the download folder |
| Download folder | KOReader's download/home folder |
| Hardcover API key | not set (or read from `hardcover.txt`) |

## Hardcover rate limit and syncing

Hardcover allows about 60 requests a minute. A sync now stays well under
that: unchanged lists are not loaded again, series are refreshed every few
days (followed series daily), several lists or series go in one request, and
requests are spaced out. If Hardcover still answers “too many requests”
(HTTP 429), the plugin waits as long as Hardcover asks, then says “Hardcover
is busy” and finishes the sync by itself in the background a few minutes
later. Everything already saved keeps working.

**Settings → Automatic Hardcover sync** syncs in the background when Wi-Fi
is on, or only on Wi-Fi while charging, every 3 to 24 hours. Wi-Fi is never
turned on for it. Optionally it also downloads up to 5 missing **Want to
read** books after each sync.

## Tags

Downloads from Hardcover get keywords: the book's genres (from Hardcover),
the Hardcover lists and shelves it is on, and its series. They show in Book
information and KOReader's file search finds them when it searches book
metadata. **Settings → Tag all attached books now** tags books you already
have.

## Shorter menu

**Settings → Menu items…** hides entries of the plugin's menu you don't use.
Search and Settings always stay.

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
| `koirc/dcc.lua` | DCC SEND receiver (with resume) |
| `koirc/syncplan.lua` | What a Hardcover sync loads again, in batches |
| `koirc/bothealth.lua` | Bot health and learned picks |
| `hcextras.lua` | Preview, series completion, auto-tag |
| `learnstore.lua` | Saves bot health, picks and finished books |
| `menuprefs.lua` | Hiding menu entries |
| `koirc/proto.lua` | IRC line, CTCP and DCC parsing |
| `koirc/results.lua` | Parses search bot result files |
| `koirc/unzip.lua` | Pure-Lua ZIP + DEFLATE reader |
