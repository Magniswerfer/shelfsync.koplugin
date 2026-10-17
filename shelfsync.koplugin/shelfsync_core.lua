--[[--
Shelf sync core: reads an OPDS acquisition feed (e.g. a Calibre-Web shelf)
and downloads the books that haven't been downloaded before. Books whose
metadata changed on the server are downloaded again, replacing the old file.

Runs in a subprocess, so it is allowed to block. It never deletes books.

@module shelfsync_core
--]]

local ShelfSync = {}

local MAX_PAGES = 50

-- Formats whose embedded metadata can be compared by a deep check
local DEEP_CHECK_FORMATS = { epub = true, kepub = true }

local MIME_FORMAT = {
    ["application/epub+zip"] = "epub",
    ["application/kepub+zip"] = "kepub",
    ["application/pdf"] = "pdf",
    ["application/x-mobi8-ebook"] = "azw3",
    ["application/x-mobipocket-ebook"] = "mobi",
    ["application/vnd.amazon.ebook"] = "azw",
    ["application/x-cbz"] = "cbz",
    ["application/vnd.comicbook+zip"] = "cbz",
    ["application/x-cbr"] = "cbr",
    ["application/x-fictionbook+xml"] = "fb2",
    ["application/rtf"] = "rtf",
    ["text/plain"] = "txt",
}

-- On-disk extension, where it differs from the format name
local FILE_EXT = {
    kepub = "kepub.epub",
}

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

-- 32-bit FNV-1a, to keep metadata fingerprints short
local function hash(str)
    local bit = require("bit")
    local h = 2166136261
    for i = 1, #str do
        h = bit.bxor(h, str:byte(i))
        h = bit.tobit(h * 16777619 % 4294967296)
    end
    return bit.tohex(h)
end

local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
                       0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function decodeXml(s)
    if not s then return nil end
    s = s:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    s = s:gsub("&#[xX](%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    s = s:gsub("&(%a+);", ENTITIES) -- unknown entities are left alone
    s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return s
end

local function parseAttrs(str)
    local attrs = {}
    for key, _, value in str:gmatch("([%w:_%-]+)%s*=%s*([\"'])(.-)%2") do
        attrs[key] = decodeXml(value)
    end
    return attrs
end

function ShelfSync.absoluteUrl(base, href)
    if href:match("^%a[%w+.%-]*:") then
        return href
    end
    local scheme, authority, path = base:match("^(%a[%w+.%-]*:)//([^/?#]*)([^?#]*)")
    if not scheme then
        return href
    end
    if href:sub(1, 2) == "//" then
        return scheme .. href
    elseif href:sub(1, 1) == "/" then
        return scheme .. "//" .. authority .. href
    elseif href:sub(1, 1) == "?" then
        return scheme .. "//" .. authority .. path .. href
    end
    return scheme .. "//" .. authority .. path:gsub("[^/]*$", "") .. href
end

local function formatOf(href, mime)
    -- Calibre-Web: /opds/download/<book_id>/<format>/
    local fmt = href:match("/download/%d+/([%w_]+)/?$") or href:match("/download/%d+/([%w_]+)/?%?")
    if fmt then
        return fmt:lower()
    end
    if mime then
        return MIME_FORMAT[mime:lower():match("^[^;%s]+")]
    end
end

--- Parses one page of an OPDS feed.
-- @treturn table { entries = { {id, title, authors, links} }, next_url }
function ShelfSync.parseFeed(xml, base_url)
    local feed = { entries = {} }
    local outside = xml:gsub("<entry[%s>].-</entry>", "")
    for attrs in outside:gmatch("<link%s(.-)/?>") do
        local a = parseAttrs(attrs)
        if a.rel == "next" and a.href then
            feed.next_url = ShelfSync.absoluteUrl(base_url, a.href)
        end
    end
    for body in xml:gmatch("<entry[%s>](.-)</entry>") do
        local entry = {
            id = decodeXml(body:match("<id>(.-)</id>") or body:match("<id%s[^>]*>(.-)</id>")),
            title = decodeXml(body:match("<title[^>]*>(.-)</title>")) or "",
            authors = {},
            links = {},
            tags = {},
            languages = {},
            summary = decodeXml(body:match("<summary[^>]*>(.-)</summary>")),
            published = decodeXml(body:match("<published[^>]*>(.-)</published>")),
            publisher = decodeXml((body:match("<publisher[%s>].-</publisher>") or ""):match("<name[^>]*>(.-)</name>")),
        }
        for attrs in body:gmatch("<category%s(.-)/?>") do
            local a = parseAttrs(attrs)
            table.insert(entry.tags, a.label or a.term or "")
        end
        for lang in body:gmatch("<dcterms:language[^>]*>(.-)</dcterms:language>") do
            table.insert(entry.languages, decodeXml(lang))
        end
        for author in body:gmatch("<author[%s>].-</author>") do
            local name = decodeXml(author:match("<name[^>]*>(.-)</name>"))
            if name and name ~= "" then
                table.insert(entry.authors, name)
            end
        end
        for attrs in body:gmatch("<link%s(.-)/?>") do
            local a = parseAttrs(attrs)
            if a.href and a.rel and a.rel:find("http://opds-spec.org/acquisition", 1, true) then
                local href = ShelfSync.absoluteUrl(base_url, a.href)
                table.insert(entry.links, { href = href, format = formatOf(href, a.type), length = a.length })
            end
        end
        if entry.id == "" then
            entry.id = nil
        end
        table.insert(feed.entries, entry)
    end
    return feed
end

--- Splits "epub, azw3 pdf" into { "epub", "azw3", "pdf" }.
function ShelfSync.parseFormats(str)
    local formats = {}
    for fmt in (str or ""):lower():gmatch("[%w_]+") do
        table.insert(formats, fmt)
    end
    return formats
end

--- Returns the acquisition link in the most preferred format, or nil.
-- With no preferred formats, any link with a known format will do.
function ShelfSync.pickLink(entry, formats)
    for _, fmt in ipairs(formats) do
        for _, link in ipairs(entry.links) do
            if link.format == fmt then
                return link
            end
        end
    end
    if #formats == 0 then
        for _, link in ipairs(entry.links) do
            if link.format then
                return link
            end
        end
    end
end

--- Fingerprint of everything the feed tells us about a book. Calibre-Web's feed
-- has no "last modified" date, so a changed fingerprint is how edits are noticed.
function ShelfSync.metaFingerprint(entry, link)
    return hash(table.concat({
        entry.title or "",
        table.concat(entry.authors, "\31"),
        table.concat(entry.tags, "\31"),
        table.concat(entry.languages, "\31"),
        entry.summary or "",
        entry.publisher or "",
        entry.published or "",
        link.format or "",
        link.length or "",
    }, "\30"))
end

function ShelfSync.fileName(entry, link)
    local name = entry.title ~= "" and entry.title or "Untitled"
    if entry.authors[1] then
        name = entry.authors[1] .. " - " .. name
    end
    return name .. "." .. (FILE_EXT[link.format] or link.format)
end

--- Runs one sync.
-- With cfg.deep_check, books already downloaded are fetched again and replaced if
-- the metadata inside the file differs. That catches edits the feed doesn't show,
-- such as the series.
-- @tparam table cfg { url, dir, formats, update_metadata, deep_check }
-- @tparam table history book id -> { file, meta }, for books downloaded before
-- @tparam table io_ { fetch(url), download(url, path), exists(path), makePath(dir), sanitize(name, dir),
--                     readMetadata(path), replace(from, to), remove(path), progress(text) }
-- @treturn table { error, unreachable, total, downloaded = {titles}, updated = {{title, path}},
--                  failed = {msgs}, skipped = {titles}, checked, timings = {lines}, history }
function ShelfSync.run(cfg, history, io_)
    local result = { total = 0, checked = 0, downloaded = {}, updated = {}, failed = {}, skipped = {}, timings = {} }
    local now = io_.now or os.time
    local started = now()
    local function timing(what, since, bytes)
        local secs = now() - since
        local line = string.format("%.1fs %s", secs, what)
        if bytes and secs > 0 then
            line = line .. string.format(" (%.0f KB, %.0f KB/s)", bytes / 1024, bytes / 1024 / secs)
        end
        table.insert(result.timings, line)
    end

    local function progress(text)
        if io_.progress then io_.progress(text) end
    end
    progress("Checking shelf…")

    local entries, seen, pages = {}, {}, 0
    local page_url = cfg.url
    while page_url and not seen[page_url] and pages < MAX_PAGES do
        seen[page_url] = true
        pages = pages + 1
        local fetch_start = now()
        local body, err, unreachable = io_.fetch(page_url)
        timing("feed page " .. pages, fetch_start, body and #body)
        if not body then
            result.error = err
            result.unreachable = unreachable
            return result
        end
        if not body:find("<feed", 1, true) then
            result.error = "Not an OPDS feed: " .. page_url
            return result
        end
        local feed = ShelfSync.parseFeed(body, page_url)
        for _, entry in ipairs(feed.entries) do
            table.insert(entries, entry)
        end
        page_url = feed.next_url
    end

    if not io_.makePath(cfg.dir) then
        result.error = "Could not create folder: " .. cfg.dir
        return result
    end

    -- Only books still on the shelf are remembered, so removing a book from
    -- the shelf and adding it again downloads it again.
    local new_history = {}
    for i, entry in ipairs(entries) do
        local step = string.format(" %s (%d/%d)", entry.title, i, #entries)
        local link = ShelfSync.pickLink(entry, cfg.formats)
        local key = entry.id or (link and link.href)
        if not link then
            table.insert(result.skipped, entry.title)
            if key then new_history[key] = history[key] end
        elseif not new_history[key] then
            result.total = result.total + 1
            local meta = ShelfSync.metaFingerprint(entry, link)
            local prev = history[key]
            if type(prev) == "string" then -- history from before metadata tracking
                prev = { file = prev }
            end
            if prev then
                -- Downloaded before. Replace it if its metadata changed, keeping the
                -- file name so reading progress stays attached. A book deleted on
                -- the device stays deleted.
                local path = cfg.dir .. "/" .. prev.file
                local changed = prev.meta and prev.meta ~= meta
                local deep = cfg.deep_check and DEEP_CHECK_FORMATS[link.format] and io_.readMetadata
                if cfg.update_metadata and (changed or deep) and io_.exists(path) then
                    progress((changed and "Updating" or "Checking") .. step)
                    local tmp = path .. ".new"
                    local dl_start = now()
                    local ok, err = io_.download(link.href, tmp)
                    timing((changed and "update: " or "check: ") .. entry.title, dl_start,
                        ok and io_.size and io_.size(tmp))
                    if ok then
                        local replace = changed
                        if not replace then
                            result.checked = result.checked + 1
                            local old_meta, new_meta = io_.readMetadata(path), io_.readMetadata(tmp)
                            replace = old_meta ~= nil and new_meta ~= nil and old_meta ~= new_meta
                        end
                        if not replace then
                            io_.remove(tmp)
                        elseif io_.replace(tmp, path) then
                            table.insert(result.updated, { title = entry.title, path = path })
                        else
                            io_.remove(tmp)
                            ok, err = false, "Could not replace file"
                        end
                    end
                    if not ok then
                        table.insert(result.failed, entry.title .. ": " .. tostring(err))
                        if changed then
                            meta = prev.meta -- retry next time
                        end
                    end
                end
                new_history[key] = { file = prev.file, meta = meta }
            else
                local filename = io_.sanitize(ShelfSync.fileName(entry, link), cfg.dir)
                local path = cfg.dir .. "/" .. filename
                local ok, err = true, nil
                if not io_.exists(path) then
                    progress("Downloading" .. step)
                    local dl_start = now()
                    ok, err = io_.download(link.href, path)
                    timing("download: " .. entry.title, dl_start, ok and io_.size and io_.size(path))
                    if ok then
                        table.insert(result.downloaded, entry.title)
                    else
                        table.insert(result.failed, entry.title .. ": " .. tostring(err))
                    end
                end
                if ok then
                    new_history[key] = { file = filename, meta = meta }
                end
            end
        end
    end
    timing("total", started)
    result.history = new_history
    return result
end

--- File and network access for ShelfSync.run, using KOReader's libraries.
function ShelfSync.koreaderIO(username, password, progress_file)
    local http = require("socket.http")
    local lfs = require("libs/libkoreader-lfs")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local util = require("util")

    if username == "" then username = nil end
    if password == "" then password = nil end

    -- Errors that mean the server can't be reached at all (e.g. away from home)
    local function isUnreachable(err)
        err = tostring(err)
        return err == "timeout" or err:find("refused", 1, true) or err:find("unreachable", 1, true)
            or err:find("host or service not provided", 1, true) or err:find("No route", 1, true)
    end

    -- Follows redirects itself, so credentials are only ever sent to the original host
    local function request(req_url, make_sink, block_timeout, total_timeout)
        local origin = req_url:match("^%a+://[^/?#]+")
        for _ = 1, 5 do
            local same_origin = req_url:match("^%a+://[^/?#]+") == origin
            socketutil:set_timeout(block_timeout, total_timeout)
            local code, headers, status = socket.skip(1, http.request{
                url = req_url,
                method = "GET",
                headers = {
                    ["Accept-Encoding"] = "identity",
                    ["User-Agent"] = socketutil.USER_AGENT,
                },
                sink = make_sink(),
                user = same_origin and username or nil,
                password = same_origin and password or nil,
                redirect = false,
            })
            socketutil:reset_timeout()
            if type(code) ~= "number" then
                return nil, tostring(code or status or "network error"), isUnreachable(code)
            end
            local location = headers and headers.location
            if code >= 300 and code < 400 and location then
                local next_url = ShelfSync.absoluteUrl(req_url, location)
                if req_url:match("^https:") and next_url:match("^http:") then
                    return nil, "Refused insecure redirect to " .. next_url
                end
                req_url = next_url
            elseif code == 200 then
                return true
            elseif code == 401 or code == 403 then
                return nil, "Login rejected (HTTP " .. code .. ")"
            else
                return nil, status or ("HTTP " .. code)
            end
        end
        return nil, "Too many redirects"
    end

    local io_ = {}

    -- The UI process polls this file to show what the sync is doing
    function io_.progress(text)
        local f = progress_file and io.open(progress_file, "w")
        if f then
            f:write(text)
            f:close()
        end
    end

    function io_.fetch(feed_url)
        local chunks
        local ok, err, unreachable = request(feed_url, function()
            chunks = {}
            return socketutil.table_sink(chunks)
        end, 5, 60) -- short connect timeout: fail fast when away from home
        if not ok then
            return nil, err, unreachable
        end
        return table.concat(chunks)
    end

    function io_.download(book_url, path)
        local part = path .. ".part"
        local ok, err = request(book_url, function()
            return socketutil.file_sink(io.open(part, "wb"))
        end, socketutil.FILE_BLOCK_TIMEOUT, 900)
        if ok and (lfs.attributes(part, "size") or 0) > 0 and os.rename(part, path) then
            return true
        end
        os.remove(part)
        return nil, err or "Could not save file"
    end

    io_.now = socket.gettime

    function io_.size(path)
        return lfs.attributes(path, "size")
    end

    function io_.exists(path)
        return lfs.attributes(path, "mode") ~= nil
    end

    function io_.replace(from, to)
        return os.rename(from, to) and true or false
    end

    function io_.remove(path)
        os.remove(path)
    end

    -- The OPF <metadata> block of an EPUB, or nil
    function io_.readMetadata(path)
        local ok, Archiver = pcall(require, "ffi/archiver")
        if not ok then
            return nil
        end
        local arc = Archiver.Reader:new()
        if not arc:open(path) then
            return nil
        end
        local opf
        for entry in arc:iterate() do
            if entry.mode == "file" and entry.path:lower():match("%.opf$") then
                opf = arc:extractToMemory(entry.path)
                break
            end
        end
        arc:close()
        return opf and opf:match("<[%w:]*metadata[%s>].-</[%w:]*metadata>")
    end

    function io_.makePath(dir)
        if lfs.attributes(dir, "mode") == "directory" then
            return true
        end
        util.makePath(dir)
        return lfs.attributes(dir, "mode") == "directory"
    end

    function io_.sanitize(name, dir)
        return util.getSafeFilename(name, dir)
    end

    return io_
end

return ShelfSync
