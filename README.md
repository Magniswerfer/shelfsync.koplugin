# Shelf sync for KOReader

A small KOReader plugin that keeps a folder on your e-reader in step with a
[Calibre-Web](https://github.com/janeczku/calibre-web) /
[Calibre-Web Automated](https://github.com/crocodilestick/Calibre-Web-Automated)
shelf. Add a book to the shelf on your computer, wake the reader at home, and
it's there.

It runs alongside KOReader's built-in OPDS plugin instead of replacing it, so
KOReader updates leave it alone.

Tested on a jailbroken Kindle Paperwhite 5 (11th gen) with KOReader v2026.07.1,
Calibre-Web Automated and the ZenUI/ZenOS plugin.

## What it does

- **Syncs automatically** when KOReader starts, on wake-up, when Wi-Fi
  connects, and every 15 minutes while KOReader is in use.
- **Skips quietly when the server can't be reached**, e.g. when you're away
  from a home-only server. Only *Sync now* reports errors.
- **Runs in the background**, so reading isn't interrupted. *Sync now* shows a
  progress toast ("Checking Ship of Magic (3/6)").
- **Downloads safely**: to a temporary file first, renamed only once complete.
- **Updates books when their metadata changes** in Calibre, keeping the file
  name so reading progress and highlights stay attached. Title, author, tags,
  description, publisher and language changes are noticed on every sync.
  Changes the OPDS feed doesn't show, such as the series, are found by
  comparing the metadata inside the EPUB files: on every *Sync now*, and once
  a day automatically.
- **Refreshes KOReader's library cache** for changed books, so covers, series
  and author groupings (including ZenUI's) show the new metadata.
- **Never deletes books.** A book you delete on the reader stays deleted; to get
  it back, remove it from the shelf and add it again, or use *Forget download
  history*.
- **Keeps a log** (*View log*) with timings for each step.

## Install

1. Copy the `shelfsync.koplugin` folder to `koreader/plugins/` on the device
   (`/mnt/us/koreader/plugins/` on a Kindle).
2. Restart KOReader.

## Set up

1. In Calibre-Web, create a shelf (e.g. "Kindle") and add some books. Open the
   shelf and copy its address, e.g. `http://192.168.1.50:8083/shelf/3`.
2. In KOReader, open **Tools → Shelf sync → Shelf** and enter:
   - the shelf address (the web page address is fine; it's turned into the OPDS
     feed `/opds/shelf/3` automatically),
   - your Calibre-Web username and password. A dedicated non-admin account is a
     good idea.
3. Tap **Sync now**.

Any OPDS acquisition feed works, not just shelves: `/opds/new`, a magic shelf,
and so on.

### Settings

| Menu item | Default |
|---|---|
| Sync automatically | On |
| Update books when metadata changes | On |
| Folder | KOReader's home folder |
| Formats, most preferred first | `epub, azw3, mobi, pdf` |

Books in none of the listed formats are skipped (and noted in the log).

## ZenUI

- **Sync button:** *Zen Settings → Interface → Launcher* (or *Controls*, or
  *Navbar*) → *Buttons* → *Add → Action* → **Sync shelf now**. Or *Add → Plugin
  Menu → Shelf sync* for the whole menu.
- **Last sync time in the status bar:** *Zen Settings → Interface → Status bar →
  Right items* → **Shelf sync (last sync)**.

The *Sync shelf now* action can also be assigned to a KOReader gesture.

## Notes

- **Use one folder.** On a Kindle, `/mnt/us` and `/mnt/base-us` are the same
  storage. Point the plugin at the same folder KOReader uses as its home
  folder (the default).
- **Embedded metadata** comes from the server: Calibre-Web writes the current
  metadata into each file it serves when "embed metadata" is on (the default in
  Calibre-Web Automated). Without it, edits may not reach the reader.
- **Passwords** are stored in plain text in `koreader/settings/shelfsync.lua`,
  like KOReader's own OPDS plugin does.
- **Logs:** `koreader/settings/shelfsync.log`.

## Development

The sync logic (`shelfsync_core.lua`) is plain Lua with its file and network
access passed in, so it can be tested on a computer with LuaJIT:

```sh
luajit spec/sync_spec.lua
luajit spec/deep_check_spec.lua
```

`main.lua` holds the KOReader side: menu, events, background process, cache
refresh and the ZenUI status item.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
