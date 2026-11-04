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

## Use

* **Search for a book…** asks for an author and/or title. The plugin turns on
  Wi‑Fi if needed, connects, joins the channel and sends `@search <your text>`.
* The search bot sends back a results file. The plugin unpacks it and shows one
  line per book with its size and the bot that has it.
* Tap a result and confirm. The plugin sends the request line (e.g.
  `!Oatmeal Author - Title.epub`) and receives the file by DCC. If the book comes
  as a `.zip` holding a single book, it is unpacked for you.
* When the download finishes you can open the book immediately.
* Tap the progress message at any time to cancel.

The connection stays open between searches so that browsing results and
downloading is quick. It closes after 5 idle minutes, when the device
sleeps, or via **Disconnect**.

## Settings

Under **IRC book search → Settings**:

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
| `koirc/fetcher.lua` | IRC session and search/download jobs (non-blocking state machine) |
| `koirc/conn.lua` | Non-blocking TCP/TLS connection |
| `koirc/dcc.lua` | DCC SEND receiver |
| `koirc/proto.lua` | IRC line, CTCP and DCC parsing |
| `koirc/results.lua` | Parses search bot result files |
| `koirc/unzip.lua` | Pure-Lua ZIP + DEFLATE reader |
