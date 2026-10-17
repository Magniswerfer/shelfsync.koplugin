--[[--
Shelf sync: keeps a folder in step with a Calibre-Web shelf, over OPDS.

Syncs when KOReader starts, on wake-up, when Wi-Fi connects, every
15 minutes while KOReader is in use, and on demand. Automatic syncs are
silently skipped when the server can't be reached (e.g. away from home).
Books are only ever added or updated, never deleted.

@module koplugin.ShelfSync
--]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local ShelfSync = require("shelfsync_core")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local buffer = require("string.buffer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiutil.template

local LOG_FILE = DataStorage:getSettingsDir() .. "/shelfsync.log"
local PROGRESS_FILE = DataStorage:getSettingsDir() .. "/shelfsync.progress"
local LOG_MAX_LINES = 200
local DEEP_CHECK_INTERVAL = 24 * 3600

local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/shelfsync.lua")
local defaults = {
    auto_sync = true,
    dir = nil, -- KOReader's home folder, see get()
    update_metadata = true,
    formats = "epub, azw3, mobi, pdf",
    interval_minutes = 15,
}
local function get(key)
    local value = settings:readSetting(key)
    if value == nil and key == "dir" then
        -- Default to the library's home folder, so books live in one place
        return G_reader_settings:readSetting("home_dir") or "/mnt/us/books"
    end
    if value == nil then
        return defaults[key]
    end
    return value
end

-- Shared by every plugin instance (FileManager and ReaderUI each get one)
local sync_pid
local started = false

local function writeLog(lines)
    local old = {}
    local f = io.open(LOG_FILE, "r")
    if f then
        for line in f:lines() do
            table.insert(old, line)
        end
        f:close()
    end
    for _, line in ipairs(lines) do
        table.insert(old, os.date("%Y-%m-%d %H:%M ") .. line)
    end
    f = io.open(LOG_FILE, "w")
    if f then
        for i = math.max(1, #old - LOG_MAX_LINES + 1), #old do
            f:write(old[i], "\n")
        end
        f:close()
    end
end

local function refreshLibraryViews()
    local zen_db = package.loaded["common/db_bookinfo"]
    if type(zen_db) == "table" and zen_db.invalidate then
        pcall(zen_db.invalidate)
    end
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end
end

-- Makes KOReader re-read title/author/series/cover for synced books whose file
-- changed since it was cached, so the library (and ZenUI's groupings) show the
-- new metadata. Books are looked up by file name: KOReader may know the folder
-- under another path (on Kindle, /mnt/us and /mnt/base-us are the same storage).
local function refreshBookInfo()
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or type(BookInfoManager) ~= "table" or not BookInfoManager.openDbConnection then
        return
    end
    local lfs = require("libs/libkoreader-lfs")
    local stale = {}
    local queried, err = pcall(function()
        BookInfoManager:openDbConnection()
        local stmt = BookInfoManager.db_conn:prepare(
            "SELECT directory, filesize, filemtime FROM bookinfo WHERE filename = ?;")
        for _, item in pairs(settings:readSetting("history") or {}) do
            local file = type(item) == "table" and item.file or item
            if type(file) == "string" then
                stmt:bind(file)
                local row = stmt:step()
                while row do
                    local path = tostring(row[1]) .. file
                    local attr = lfs.attributes(path)
                    if attr and (tonumber(row[2]) ~= attr.size or tonumber(row[3]) ~= attr.modification) then
                        table.insert(stale, path)
                    end
                    row = stmt:step()
                end
                stmt:clearbind():reset()
            end
        end
        stmt:close()
    end)
    if not queried then
        logger.warn("ShelfSync: could not read book info cache:", err)
        return
    end
    if #stale == 0 then
        return
    end
    local to_extract = {}
    for _, path in ipairs(stale) do
        pcall(BookInfoManager.deleteBookInfo, BookInfoManager, path)
        table.insert(to_extract, { filepath = path })
    end
    logger.info("ShelfSync: refreshing book info for", #stale, "books")
    writeLog({ "Refreshed library info for " .. #stale .. " changed books" })
    -- Re-read them in the background, then redraw the library
    if BookInfoManager.extractInBackground then
        pcall(BookInfoManager.extractInBackground, BookInfoManager, to_extract)
    end
    refreshLibraryViews()
    UIManager:scheduleIn(5, refreshLibraryViews)
    UIManager:scheduleIn(15, refreshLibraryViews)
end

-- Shows the last sync time in ZenUI's status bar, if ZenUI is installed.
-- The item still has to be switched on in ZenUI's status bar settings.
local function updateZenStatus()
    local register = rawget(_G, "__ZEN_UI_REGISTER_STATUS_ITEM") or rawget(_G, "__ZENOS_REGISTER_STATUS_ITEM")
    if type(register) ~= "function" then
        return
    end
    register("shelfsync", function()
        if sync_pid then
            return "\u{F04E6}", _("Syncing…")
        end
        local last = settings:readSetting("last_success")
        if not last then
            return "\u{F04E6}", _("Never")
        end
        local same_day = os.date("%Y%m%d", last) == os.date("%Y%m%d")
        return "\u{F04E6}", os.date(same_day and "%H:%M" or "%d %b", last)
    end, { label = _("Shelf sync (last sync)"), side = "right" })
end

-- Accepts the shelf's web page address too, and turns it into its OPDS feed
local function normalizeUrl(url)
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then
        return nil
    end
    if not url:match("^%a+://") then
        url = "http://" .. url
    end
    local base, id = url:match("^(.-)/shelf/(%d+)/?$")
    if base and not base:match("/opds$") then
        url = base .. "/opds/shelf/" .. id
    end
    return url
end

local function onSyncDone(result, manual)
    local log = {}
    if result.error then
        if result.unreachable and not manual then
            logger.info("ShelfSync: server unreachable, skipping:", result.error)
            updateZenStatus()
            return
        end
        table.insert(log, "Error: " .. result.error)
        settings:saveSetting("last_result", T(_("Failed: %1"), result.error))
        updateZenStatus()
        if manual then
            UIManager:show(InfoMessage:new{
                text = T(_("Shelf sync failed:\n%1"), result.error),
                icon = "notice-warning",
            })
        end
    else
        settings:saveSetting("history", result.history)
        if result.checked and result.checked > 0 then
            settings:saveSetting("last_deep_check", os.time())
        end
        settings:saveSetting("last_success", os.time())
        local updated = result.updated or {}
        local summary = T(_("%1 new, %2 updated, %3 on shelf"), #result.downloaded, #updated, result.total)
        if #result.failed > 0 then
            summary = summary .. ", " .. T(_("%1 failed"), #result.failed)
        end
        settings:saveSetting("last_result", summary)
        table.insert(log, "Synced: " .. summary)
        for _, line in ipairs(result.timings or {}) do
            table.insert(log, "  Time: " .. line)
        end
        for _, title in ipairs(result.downloaded) do
            table.insert(log, "  Downloaded: " .. title)
        end
        for _, book in ipairs(updated) do
            table.insert(log, "  Updated: " .. book.title)
        end
        if result.checked and result.checked > 0 then
            table.insert(log, "  Checked embedded metadata of " .. result.checked .. " books")
        end
        -- Make the library re-read changed books. Again a bit later, in case the
        -- library was still reading an old file while it was being replaced.
        refreshBookInfo()
        UIManager:scheduleIn(30, refreshBookInfo)
        for _, msg in ipairs(result.failed) do
            table.insert(log, "  Failed: " .. msg)
        end
        for _, title in ipairs(result.skipped) do
            table.insert(log, "  No wanted format: " .. title)
        end
        if #result.downloaded > 0 then
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then
                FileManager.instance:onRefresh()
            end
        end
        if #result.downloaded > 0 or #updated > 0 or manual then
            local text = T(N_("Shelf sync: 1 new book", "Shelf sync: %1 new books", #result.downloaded),
                #result.downloaded)
            if #updated > 0 then
                text = text .. ", " .. T(N_("1 updated", "%1 updated", #updated), #updated)
            end
            UIManager:show(Notification:new{ text = text })
        end
        if #result.failed > 0 and manual then
            UIManager:show(InfoMessage:new{
                text = T(_("Some books could not be downloaded:\n%1"), table.concat(result.failed, "\n")),
            })
        end
    end
    settings:flush()
    writeLog(log)
    updateZenStatus()
end

-- Toast shown while a manual sync runs, updated as it goes
local progress_toast
local function showProgress(text)
    if progress_toast then
        UIManager:close(progress_toast)
        progress_toast = nil
    end
    if text then
        progress_toast = Notification:new{ text = T(_("Shelf sync: %1"), text), timeout = 600 }
        UIManager:show(progress_toast)
    end
end

local function startSync(manual)
    -- A deep check re-downloads books to compare their embedded metadata (e.g. series):
    -- on every manual sync, and at most once a day automatically
    local deep_check = manual
        or os.time() - (settings:readSetting("last_deep_check") or 0) >= DEEP_CHECK_INTERVAL
    if sync_pid then
        if manual then
            UIManager:show(InfoMessage:new{ text = _("Shelf sync is already running."), timeout = 2 })
        end
        return
    end
    local url = settings:readSetting("url")
    if not url then
        if manual then
            UIManager:show(InfoMessage:new{ text = _("Set the shelf address first.") })
        end
        return
    end
    local dir = get("dir")
    local cfg = {
        url = url,
        dir = dir,
        formats = ShelfSync.parseFormats(get("formats")),
        update_metadata = get("update_metadata"),
        deep_check = deep_check,
    }
    local username, password = settings:readSetting("username"), settings:readSetting("password")

    -- The download history belongs to one shelf and folder. After switching folders,
    -- keep the books that are already in the new one (e.g. the same folder under
    -- another path), so they aren't downloaded again under a new name.
    local history = settings:readSetting("history") or {}
    local history_for = settings:readSetting("history_for")
    if history_for ~= url .. "\n" .. dir then
        local kept = {}
        if history_for and history_for:match("^[^\n]*") == url then
            local lfs = require("libs/libkoreader-lfs")
            for key, item in pairs(history) do
                local file = type(item) == "table" and item.file or item
                if type(file) == "string" and lfs.attributes(dir .. "/" .. file, "mode") == "file" then
                    kept[key] = item
                end
            end
        end
        history = kept
        settings:saveSetting("history", history)
        settings:saveSetting("history_for", url .. "\n" .. dir)
    end
    settings:saveSetting("last_attempt", os.time())
    settings:flush()

    os.remove(PROGRESS_FILE)
    local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, result = pcall(function()
            return ShelfSync.run(cfg, history, ShelfSync.koreaderIO(username, password, PROGRESS_FILE))
        end)
        if not ok then
            result = { error = tostring(result) }
        end
        ffiutil.writeToFD(write_fd, buffer.encode(result), true)
    end, true)
    if not pid then
        logger.warn("ShelfSync: could not start subprocess:", read_fd)
        return
    end
    sync_pid = pid
    updateZenStatus()
    local shown_progress
    if manual then
        shown_progress = _("Starting…")
        showProgress(shown_progress)
    end

    local function poll()
        -- Read as soon as there's data: a large result may not fit in the pipe buffer
        if ffiutil.getNonBlockingReadSize(read_fd) == 0 and not ffiutil.isSubProcessDone(sync_pid) then
            if manual then
                local f = io.open(PROGRESS_FILE, "r")
                local text = f and f:read("*a")
                if f then f:close() end
                if text and text ~= "" and text ~= shown_progress then
                    shown_progress = text
                    showProgress(text)
                end
            end
            UIManager:scheduleIn(1, poll)
            return
        end
        showProgress(nil)
        os.remove(PROGRESS_FILE)
        local data = ffiutil.readAllFromFD(read_fd)
        ffiutil.isSubProcessDone(sync_pid, true)
        sync_pid = nil
        local ok, result = pcall(buffer.decode, data)
        if not ok or type(result) ~= "table" then
            result = { error = _("Sync stopped unexpectedly.") }
        end
        onSyncDone(result, manual)
    end
    UIManager:scheduleIn(1, poll)
end

local function autoSync()
    if not get("auto_sync") or sync_pid then
        return
    end
    local since = os.time() - (settings:readSetting("last_attempt") or 0)
    if since < get("interval_minutes") * 60 then
        return
    end
    if not NetworkMgr:isConnected() then
        return
    end
    startSync(false)
end

local function periodicSync()
    autoSync()
    UIManager:scheduleIn(get("interval_minutes") * 60, periodicSync)
end

local ShelfSyncPlugin = WidgetContainer:extend{
    name = "shelfsync",
    is_doc_only = false,
}

function ShelfSyncPlugin:init()
    Dispatcher:registerAction("shelfsync_sync", {
        category = "none", event = "ShelfSyncNow", title = _("Sync shelf now"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    -- ZenUI loads after us, so register once every plugin is initialized
    UIManager:nextTick(updateZenStatus)
    if not started then
        -- Once per KOReader session: sync shortly after start, then periodically
        started = true
        UIManager:scheduleIn(10, periodicSync)
        UIManager:scheduleIn(15, refreshBookInfo)
    end
end

function ShelfSyncPlugin:onShelfSyncNow()
    NetworkMgr:runWhenOnline(function() startSync(true) end)
    return true
end

function ShelfSyncPlugin:onResume()
    -- Give Wi-Fi a moment to come back; NetworkConnected will also trigger us
    UIManager:unschedule(autoSync)
    UIManager:scheduleIn(5, autoSync)
end

function ShelfSyncPlugin:onNetworkConnected()
    UIManager:unschedule(autoSync)
    UIManager:scheduleIn(2, autoSync)
end

function ShelfSyncPlugin:showAddressDialog(touchmenu_instance)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Calibre-Web shelf"),
        fields = {
            {
                text = settings:readSetting("url") or "",
                hint = "http://192.168.1.10:8083/opds/shelf/1",
            },
            {
                text = settings:readSetting("username") or "",
                hint = _("Username"),
            },
            {
                text = settings:readSetting("password") or "",
                hint = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        settings:saveSetting("url", normalizeUrl(fields[1]))
                        settings:saveSetting("username", fields[2] ~= "" and fields[2] or nil)
                        settings:saveSetting("password", fields[3] ~= "" and fields[3] or nil)
                        settings:flush()
                        UIManager:close(dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ShelfSyncPlugin:showFormatsDialog(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Formats, most preferred first"),
        input = get("formats"),
        description = _("The first format the book is available in is downloaded. Books in none of these formats are skipped."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        settings:saveSetting("formats", dialog:getInputText())
                        settings:flush()
                        UIManager:close(dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ShelfSyncPlugin:addToMainMenu(menu_items)
    menu_items.shelfsync = {
        text = _("Shelf sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync now"),
                keep_menu_open = true,
                callback = function()
                    self:onShelfSyncNow()
                end,
            },
            {
                text_func = function()
                    local last = settings:readSetting("last_success")
                    return T(_("Last sync: %1"), last and os.date("%Y-%m-%d %H:%M", last) or _("never"))
                end,
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = settings:readSetting("last_result") or _("Not synced yet."),
                    })
                end,
                separator = true,
            },
            {
                text = _("Sync automatically"),
                help_text = _("Sync when KOReader starts, on wake-up, when Wi-Fi connects, and every 15 minutes while in use. Skipped quietly when the server can't be reached."),
                checked_func = function()
                    return get("auto_sync")
                end,
                callback = function()
                    settings:saveSetting("auto_sync", not get("auto_sync"))
                    settings:flush()
                end,
            },
            {
                text = _("Update books when metadata changes"),
                help_text = _("When a book's metadata changes on the server, download it again and replace the file on the Kindle. Reading progress and highlights are kept.\n\nTitle, author, tags, description, publisher and language changes are noticed on every sync. Other changes, such as the series, are found by comparing the files themselves: on Sync now, and once a day automatically."),
                checked_func = function()
                    return get("update_metadata")
                end,
                callback = function()
                    settings:saveSetting("update_metadata", not get("update_metadata"))
                    settings:flush()
                end,
            },
            {
                text_func = function()
                    return T(_("Shelf: %1"), settings:readSetting("url") or _("not set"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showAddressDialog(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return T(_("Folder: %1"), get("dir"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local PathChooser = require("ui/widget/pathchooser")
                    local lfs = require("libs/libkoreader-lfs")
                    local dir = get("dir")
                    UIManager:show(PathChooser:new{
                        select_directory = true,
                        select_file = false,
                        show_files = false,
                        path = lfs.attributes(dir, "mode") == "directory" and dir or "/mnt/us",
                        onConfirm = function(path)
                            settings:saveSetting("dir", path)
                            settings:flush()
                            touchmenu_instance:updateItems()
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Formats: %1"), get("formats"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showFormatsDialog(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text = _("View log"),
                keep_menu_open = true,
                callback = function()
                    local f = io.open(LOG_FILE, "r")
                    local text = f and f:read("*a") or ""
                    if f then f:close() end
                    UIManager:show(TextViewer:new{
                        title = _("Shelf sync log"),
                        text = text ~= "" and text or _("Nothing logged yet."),
                    })
                end,
            },
            {
                text = _("Forget download history"),
                help_text = _("Books are downloaded only once, so deleting a book on the Kindle doesn't bring it back. Forgetting the history downloads every book on the shelf that isn't in the folder."),
                keep_menu_open = true,
                callback = function()
                    settings:saveSetting("history", {})
                    settings:flush()
                    UIManager:show(InfoMessage:new{ text = _("Download history cleared."), timeout = 2 })
                end,
            },
        },
    }
end

return ShelfSyncPlugin
