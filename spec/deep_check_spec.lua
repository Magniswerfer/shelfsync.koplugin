package.path = (arg[1] or "shelfsync.koplugin") .. "/?.lua;" .. package.path
local S = require("shelfsync_core")
local feed = [[<feed><entry><title>Ship of Magic</title><id>urn:uuid:5</id><author><name>Robin Hobb</name></author>
<link rel="http://opds-spec.org/acquisition" href="/opds/download/5/epub/" length="1" type="application/epub+zip"/></entry>
<entry><title>A PDF</title><id>urn:uuid:6</id><link rel="http://opds-spec.org/acquisition" href="/opds/download/6/pdf/" type="application/pdf"/></entry></feed>]]
local server_series = "Liveship Traders Trilogy"
local files, downloads = {}, 0
local io_ = {
  fetch = function() return feed end,
  download = function(u, p) downloads = downloads + 1; files[p] = u:find("/5/") and ("series=" .. server_series) or "pdf"; return true end,
  exists = function(p) return files[p] ~= nil end,
  makePath = function() return true end,
  sanitize = function(n) return n end,
  readMetadata = function(p) return files[p] and files[p]:match("series=.*") end,
  replace = function(a, b) files[b] = files[a]; files[a] = nil; return true end,
  remove = function(p) files[p] = nil end,
}
local function check(c, m) if not c then error("FAIL " .. m, 2) end print("ok  " .. m) end
local cfg = { url = "http://h/opds/shelf/1", dir = "/b", formats = {"epub", "pdf"}, update_metadata = true }
local r1 = S.run(cfg, {}, io_)
check(#r1.downloaded == 2, "both downloaded")
server_series = "Liveship Traders"
cfg.deep_check = false
downloads = 0
local r2 = S.run(cfg, r1.history, io_)
check(downloads == 0 and #r2.updated == 0, "series-only change not seen without deep check")
cfg.deep_check = true
local r3 = S.run(cfg, r2.history, io_)
check(#r3.updated == 1 and files["/b/Robin Hobb - Ship of Magic.epub"] == "series=Liveship Traders", "deep check replaces book with new series")
check(downloads == 1 and r3.checked == 1, "pdf not re-downloaded by deep check")
check(files["/b/Robin Hobb - Ship of Magic.epub.new"] == nil, "temp file cleaned up")
downloads = 0
local r4 = S.run(cfg, r3.history, io_)
check(#r4.updated == 0 and downloads == 1 and files["/b/Robin Hobb - Ship of Magic.epub.new"] == nil, "unchanged: checked, not replaced, temp removed")
print("deep passed")
