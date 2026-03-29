-- ProjectTitle: Contextual Display Mode (Home vs Subfolders)
-- Adds menu options to set a different display mode for the home folder and subfolders.
-- The mode switches automatically when navigating between home and subfolders.
-- Settings are persistent via G_reader_settings under the "pt_contextual_display" key.
--
-- Injected at the top of the ProjectTitle display-mode menu:
--   [✓] Use different mode for Home and subfolders
--       Home folder mode ▶  (enabled when above is checked)
--       Subfolder mode   ▶  (enabled when above is checked)

local FileChooser = require("ui/widget/filechooser")
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local logger = require("logger")

-- ────────────────────────────────────────────────────────────
-- Settings (stored in G_reader_settings — always available)
-- ────────────────────────────────────────────────────────────

local SETTINGS_KEY = "pt_contextual_display"
local LOGPFX = "[PT-ContextualDisplay]"

local DEFAULTS = {
    enabled           = false,
    home_display_mode = "mosaic_image",
    sub_display_mode  = "list_image_meta",
}

local function loadSettings()
    local s = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(s) ~= "table" then s = {} end
    for k, v in pairs(DEFAULTS) do
        if s[k] == nil then s[k] = v end
    end
    return s
end

local function saveSettings(s)
    G_reader_settings:saveSetting(SETTINGS_KEY, s)
end

-- ────────────────────────────────────────────────────────────
-- Display modes — must match ProjectTitle's CoverBrowser.modes
-- ────────────────────────────────────────────────────────────

local MODES = {
    { "Cover List",     "list_image_meta" },
    { "Cover Grid",     "mosaic_image" },
    { "Details List",   "list_only_meta" },
    { "Filenames List", "list_no_meta" },
}

-- ────────────────────────────────────────────────────────────
-- Helper: apply the contextual mode for the given path
-- ────────────────────────────────────────────────────────────

local function applyContextualMode(path)
    local s = loadSettings()
    if not s.enabled then return end
    local home_dir = G_reader_settings:readSetting("home_dir")
    if not home_dir then return end

    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if not fm or not fm.coverbrowser then return end

    local target_mode
    if path == home_dir then
        target_mode = s.home_display_mode
        logger.dbg(LOGPFX, "At home → applying home mode:", target_mode)
    else
        target_mode = s.sub_display_mode
        logger.dbg(LOGPFX, "In subfolder → applying subfolder mode:", target_mode)
    end

    -- Guard: if the file chooser's item_table is not yet populated or is empty (e.g. we are
    -- inside FileChooser:changeToPath→onMenuSelect, before updateItems has run),
    -- defer the mode switch to the next UI tick so that refreshFileManagerInstance
    -- does not call switchItemTable on an empty item_table and crash on index 0.
    local UIManager = require("ui/uimanager")
    local fc = fm.file_chooser
    if fc and (not fc.item_table or #fc.item_table == 0) then
        logger.dbg(LOGPFX, "item_table not ready or empty, deferring mode switch to nextTick")
        UIManager:nextTick(function()
            -- Re-fetch fm in case the instance changed between ticks
            local fm2 = FileManager.instance
            if fm2 and fm2.coverbrowser and fm2.file_chooser and fm2.file_chooser.item_table and #fm2.file_chooser.item_table > 0 then
                fm2.coverbrowser:setupFileManagerDisplayMode(target_mode)
            end
        end)
        return
    end

    fm.coverbrowser:setupFileManagerDisplayMode(target_mode)
end


-- ────────────────────────────────────────────────────────────
-- Helper: inject contextual-mode entries into CoverBrowser's menu
-- Called from the wrapped addToMainMenu AFTER CoverBrowser has populated menu_items
-- ────────────────────────────────────────────────────────────

local function getCoverBrowser()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    return fm and fm.coverbrowser
end

local function applyMode(mode)
    local cb = getCoverBrowser()
    if cb then cb:setupFileManagerDisplayMode(mode) end
end

local function injectContextualMenuEntries(menu_items)
    -- Guard: only when ProjectTitle's display-mode entry is present
    if not menu_items.filemanager_display_mode then return end
    local display_menu = menu_items.filemanager_display_mode
    if not display_menu.sub_item_table then return end

    local sub = display_menu.sub_item_table

    -- Build home / subfolder mode selectors
    local home_sub   = {}
    local subfol_sub = {}

    for i, v in ipairs(MODES) do
        local label, mode = v[1], v[2]

        home_sub[i] = {
            text = label,
            checked_func = function()
                return loadSettings().home_display_mode == mode
            end,
            callback = function()
                local s = loadSettings()
                s.home_display_mode = mode
                saveSettings(s)
                if s.enabled then
                    local cb = getCoverBrowser()
                    local fc = cb and cb.ui and cb.ui.file_chooser
                    local home_dir = G_reader_settings:readSetting("home_dir")
                    if fc and home_dir and fc.path == home_dir then
                        applyMode(mode)
                    end
                end
            end,
        }

        subfol_sub[i] = {
            text = label,
            checked_func = function()
                return loadSettings().sub_display_mode == mode
            end,
            callback = function()
                local s = loadSettings()
                s.sub_display_mode = mode
                saveSettings(s)
                if s.enabled then
                    local cb = getCoverBrowser()
                    local fc = cb and cb.ui and cb.ui.file_chooser
                    local home_dir = G_reader_settings:readSetting("home_dir")
                    if fc and (home_dir == nil or fc.path ~= home_dir) then
                        applyMode(mode)
                    end
                end
            end,
        }
    end

    -- Find insertion point: right after the first block of modes (which ends with a separator)
    -- This avoids relying on translated text like "Use this mode everywhere" which fails in localized UI
    local insert_at = 5 -- Fallback: the 4 modes take indices 1 to 4
    for i, item in ipairs(sub) do
        if item.separator then
            insert_at = i + 1
            break
        end
    end

    -- ① Checkbox
    table.insert(sub, insert_at, {
        text = "Use different mode for Home and subfolders",
        checked_func = function()
            return loadSettings().enabled
        end,
        callback = function()
            local s = loadSettings()
            s.enabled = not s.enabled
            saveSettings(s)
            local cb = getCoverBrowser()
            local fc = cb and cb.ui and cb.ui.file_chooser
            if fc then
                local home_dir = G_reader_settings:readSetting("home_dir")
                if s.enabled then
                    if home_dir and fc.path == home_dir then
                        applyMode(s.home_display_mode)
                    else
                        applyMode(s.sub_display_mode)
                    end
                else
                    -- revert to the plugin's saved global mode
                    local bim = package.loaded["bookinfomanager"]
                    local fallback = bim and bim:getSetting("filemanager_display_mode")
                        or "list_image_meta"
                    applyMode(fallback)
                end
            end
        end,
        separator = false,
    })

    -- ② Home folder mode
    table.insert(sub, insert_at + 1, {
        text = "Home folder mode",
        enabled_func = function()
            return loadSettings().enabled
        end,
        sub_item_table = home_sub,
    })

    -- ③ Subfolder mode
    table.insert(sub, insert_at + 2, {
        text = "Subfolder mode",
        separator = true,
        enabled_func = function()
            return loadSettings().enabled
        end,
        sub_item_table = subfol_sub,
    })

    logger.dbg(LOGPFX, "Contextual display mode entries injected")
end

-- ────────────────────────────────────────────────────────────
-- Hook 1: FileManagerMenu:registerToMainMenu
-- When CoverBrowser (ProjectTitle) registers itself, wrap its addToMainMenu
-- so we can inject our entries after it runs.
-- ────────────────────────────────────────────────────────────

local orig_registerToMainMenu = FileManagerMenu.registerToMainMenu

function FileManagerMenu:registerToMainMenu(widget)
    -- Intercept CoverBrowser (ProjectTitle plugin)
    if widget.name == "coverbrowser" then
        local orig_widget_addToMainMenu = widget.addToMainMenu

        widget.addToMainMenu = function(w, menu_items)
            -- Call the original ProjectTitle menu builder first
            orig_widget_addToMainMenu(w, menu_items)
            -- Then inject our contextual-mode entries
            injectContextualMenuEntries(menu_items)
        end

        logger.dbg(LOGPFX, "Wrapped CoverBrowser.addToMainMenu")
    end

    orig_registerToMainMenu(self, widget)
end

-- ────────────────────────────────────────────────────────────
-- Hook 2: FileChooser:changeToPath
-- Fires on every directory navigation.  Applies the contextual mode.
-- ────────────────────────────────────────────────────────────

local orig_changeToPath = FileChooser.changeToPath

function FileChooser:changeToPath(path, focused_path)
    orig_changeToPath(self, path, focused_path)
    if self.name == "filemanager" then
        local ffiUtil = require("ffi/util")
        local real = ffiUtil.realpath(path)
        if real then
            applyContextualMode(real)
        end
    end
end

-- ────────────────────────────────────────────────────────────
-- Hook 3: FileManager:init
-- Covers the case where FileManager is created fresh via FileManager:showFiles()
-- (e.g. from the reader home-icon patch). In that case, ProjectTitle books a
-- nextTick callback in its `setupLayout` replacement that forces the global
-- 'filemanager_display_mode' setting, overriding our contextual logic.
-- We hook the end of `FileManager:init` and schedule a `tickAfterNext` callback,
-- ensuring our contextual mode is applied AFTER ProjectTitle's forced reset.
-- ────────────────────────────────────────────────────────────

local FileManager = require("apps/filemanager/filemanager")
local orig_init = FileManager.init

function FileManager:init()
    orig_init(self)
    
    -- Execute synchronously at the end of init, so the correct mode is applied
    -- BEFORE FileManager:showFiles() calls UIManager:show() and paints the screen.
    local s = loadSettings()
    if s.enabled and self.file_chooser and self.file_chooser.path then
        local home_dir = G_reader_settings:readSetting("home_dir")
        if home_dir then
            local ffiUtil = require("ffi/util")
            local real = ffiUtil.realpath(self.file_chooser.path)
            if real then
                local target_mode = (real == home_dir)
                    and s.home_display_mode
                    or  s.sub_display_mode
                local cb = getCoverBrowser()
                if cb then
                    local current = cb.curr_display_modes and cb.curr_display_modes["filemanager"]
                    if target_mode ~= current then
                        cb:setupFileManagerDisplayMode(target_mode)
                    end
                end
            end
        end
    end
end


