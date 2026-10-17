package.path = (arg[1] or "shelfsync.koplugin") .. "/?.lua;" .. package.path
local S = require("shelfsync_core")
local function page(entries, next_href)
  return [[<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>urn:uuid:feed</id>
  <link rel="self" href="/opds/shelf/3?" type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
  <link rel="start" href="/opds" type="application/atom+xml"/>]] ..
  (next_href and ('\n  <link rel="next"\n        title="Next"\n        href="' .. next_href .. '"\n        type="application/atom+xml"/>') or "") ..
  "\n  <title>CWA</title>\n  <author>\n    <name>CWA</name>\n  </author>\n" .. entries .. "</feed>"
end
local function entry(id, title, author, fmts)
  local links = {}
  for _, f in ipairs(fmts) do
    links[#links+1] = '    <link rel="http://opds-spec.org/acquisition" href="/opds/download/' .. id .. '/' .. f[1] .. '/"\n          length="1" mtime="x" type="' .. f[2] .. '"/>'
  end
  return "  <entry>\n    <title>" .. title .. "</title>\n    <id>urn:uuid:" .. id .. "</id>\n    <updated>2026</updated>\n      <author>\n        <name>" .. author .. "</name>\n      </author>\n" ..
    '    <link type="image/jpeg" href="/opds/cover/' .. id .. '" rel="http://opds-spec.org/image"/>\n' .. table.concat(links, "\n") .. "\n  </entry>\n"
end
local EPUB, PDF, AZW3 = {"epub","application/epub+zip"}, {"pdf","application/pdf"}, {"azw3","application/x-mobi8-ebook"}
local pages = {
  ["http://192.168.1.10:8083/opds/shelf/3"] = page(entry(1, "Dune &amp; Friends", "Frank Herbert", {PDF, EPUB}) .. entry(2, "R&#xE9;sum&#233;", "Émile", {AZW3}), "/opds/shelf/3?offset=2"),
  ["http://192.168.1.10:8083/opds/shelf/3?offset=2"] = page(entry(3, "Only PDF", "X", {PDF}) .. entry(4, "Broken", "Y", {EPUB})),
}
local files, downloads = {}, {}
local function newIO(unreachable)
  return {
    fetch = function(u) if unreachable then return nil, "connection refused", true end return pages[u], pages[u] and nil or "HTTP 404" end,
    download = function(u, p) downloads[#downloads+1] = u; if u:find("/4/") then return nil, "HTTP 500" end files[p] = true; return true end,
    exists = function(p) return files[p] or false end,
    makePath = function() return true end,
    sanitize = function(n) return (n:gsub("[/:]", "_")) end,
    replace = function(a, b) files[b] = files[a]; files[a] = nil; return true end,
    remove = function(p) files[p] = nil end,
  }
end
local function check(c, msg) if not c then error("FAIL: " .. msg, 2) end print("ok  " .. msg) end
local cfg = { url = "http://192.168.1.10:8083/opds/shelf/3", dir = "/mnt/us/documents/Books", formats = S.parseFormats("epub, azw3"), update_metadata = true }

local r = S.run(cfg, {}, newIO())
check(not r.error, "no error")
check(r.total == 3, "3 books with wanted format (got " .. r.total .. ")")
check(#r.downloaded == 2, "2 downloaded")
check(r.downloaded[1] == "Dune & Friends", "entity decoded: " .. r.downloaded[1])
check(r.downloaded[2] == "Résumé", "numeric entities decoded: " .. r.downloaded[2])
check(downloads[1] == "http://192.168.1.10:8083/opds/download/1/epub/", "epub preferred over pdf, absolute url: " .. downloads[1])
check(files["/mnt/us/documents/Books/Frank Herbert - Dune & Friends.epub"], "file name Author - Title.ext")
check(#r.skipped == 1 and r.skipped[1] == "Only PDF", "pdf-only skipped")
check(#r.failed == 1 and r.failed[1]:find("HTTP 500"), "failed download reported")
check(r.history["urn:uuid:1"] and r.history["urn:uuid:2"] and not r.history["urn:uuid:4"], "history has successes only")

-- second run: nothing new; failed one retried
downloads = {}
local r2 = S.run(cfg, r.history, newIO())
check(#r2.downloaded == 0 and #downloads == 1 and downloads[1]:find("/4/"), "second run only retries the failed book")

-- user deleted book 1 locally: not re-downloaded
files["/mnt/us/documents/Books/Frank Herbert - Dune & Friends.epub"] = nil
downloads = {}
local r3 = S.run(cfg, r2.history, newIO())
check(not downloads[1] or not downloads[1]:find("/1/"), "locally deleted book is not re-downloaded")

-- book 1 removed from shelf then re-added: downloaded again
local h = {}; for k, v in pairs(r3.history) do h[k] = v end
h["urn:uuid:1"] = nil
downloads = {}
S.run(cfg, h, newIO())
check(downloads[1] == "http://192.168.1.10:8083/opds/download/1/epub/", "re-added book downloads again")

-- away from home
local r4 = S.run(cfg, r3.history, newIO(true))
check(r4.error and r4.unreachable, "unreachable flagged")

-- metadata tracking
files = {}; downloads = {}
local m1 = S.run(cfg, {}, newIO())
local base = "http://192.168.1.10:8083/opds/shelf/3"
local orig = pages[base]
pages[base] = orig:gsub("Dune &amp; Friends", "Dune (Revised)")
downloads = {}
local m2 = S.run(cfg, m1.history, newIO())
check(#m2.updated == 1 and m2.updated[1].path == "/mnt/us/documents/Books/Frank Herbert - Dune & Friends.epub", "changed title re-downloads into the same file")
check(#m2.downloaded == 0, "update is not counted as new")
downloads = {}
local m3 = S.run(cfg, m2.history, newIO())
check(#m3.updated == 0 and not (downloads[1] or ""):find("/1/"), "no update when unchanged")
pages[base] = orig
files["/mnt/us/documents/Books/Frank Herbert - Dune & Friends.epub"] = nil
downloads = {}
local m4 = S.run(cfg, m3.history, newIO())
check(#m4.updated == 0 and not (downloads[1] or ""):find("/1/"), "changed but deleted locally: stays deleted")
files["/mnt/us/documents/Books/Frank Herbert - Dune & Friends.epub"] = true
pages[base] = orig:gsub("Frank Herbert", "F. Herbert")
local off = {}; for k, v in pairs(cfg) do off[k] = v end; off.update_metadata = false
downloads = {}
local m5 = S.run(off, m4.history, newIO())
check(#m5.updated == 0 and #m5.downloaded == 0, "updates off: nothing downloaded")
downloads = {}
local m6 = S.run(cfg, m5.history, newIO())
check(#m6.updated == 0, "turning updates on later doesn't replay old changes")
local legacy = { ["urn:uuid:1"] = "Frank Herbert - Dune & Friends.epub" }
downloads = {}
local m7 = S.run(cfg, legacy, newIO())
check(#m7.updated == 0 and m7.history["urn:uuid:1"].meta, "old-style history upgraded without re-downloading")
pages[base] = orig

check(S.absoluteUrl("http://h:1/a/b?x", "c") == "http://h:1/a/c", "relative url")
-- metadata tracking
files = {}; downloads = {}
local m1 = S.run(cfg, {}, newIO())
local base = "http://192.168.1.10:8083/opds/shelf/3"
local orig = pages[base]
pages[base] = orig:gsub("Dune &amp; Friends", "Dune (Revised)")
downloads = {}
local m2 = S.run(cfg, m1.history, newIO())
check(#m2.updated == 1 and m2.updated[1].path == "/mnt/us/documents/Books/Frank Herbert - Dune & Friends.epub", "changed title re-downloads into the same file")
check(#m2.downloaded == 0, "update is not counted as new")
downloads = {}
local m3 = S.run(cfg, m2.history, newIO())
check(#m3.updated == 0 and not (downloads[1] or ""):find("/1/"), "no update when unchanged")
pages[base] = orig
files["/mnt/us/documents/Books/Frank Herbert - Dune & Friends.epub"] = nil
downloads = {}
local m4 = S.run(cfg, m3.history, newIO())
check(#m4.updated == 0 and not (downloads[1] or ""):find("/1/"), "changed but deleted locally: stays deleted")
files["/mnt/us/documents/Books/Frank Herbert - Dune & Friends.epub"] = true
pages[base] = orig:gsub("Frank Herbert", "F. Herbert")
local off = {}; for k, v in pairs(cfg) do off[k] = v end; off.update_metadata = false
downloads = {}
local m5 = S.run(off, m4.history, newIO())
check(#m5.updated == 0 and #m5.downloaded == 0, "updates off: nothing downloaded")
downloads = {}
local m6 = S.run(cfg, m5.history, newIO())
check(#m6.updated == 0, "turning updates on later doesn't replay old changes")
local legacy = { ["urn:uuid:1"] = "Frank Herbert - Dune & Friends.epub" }
downloads = {}
local m7 = S.run(cfg, legacy, newIO())
check(#m7.updated == 0 and m7.history["urn:uuid:1"].meta, "old-style history upgraded without re-downloading")
pages[base] = orig

check(S.absoluteUrl("https://h/a", "//g/x") == "https://g/x", "scheme-relative url")
print("all passed")
