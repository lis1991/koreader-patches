-- 22-fallback-font_RC6.lua
--
-- Choose 5 extra fallback fonts using KOReader's native font menu entries
-- (text_func + menu_item_id), with persistent storage in global settings
-- (G_reader_settings).

local _ = _ or function(s) return s end

local unpack = table.unpack or unpack

local ok_cre, CreDocument = pcall(require, "document/credocument")
if not ok_cre or not CreDocument then
    return
end

local ok_rf, ReaderFont = pcall(require, "apps/reader/modules/readerfont")
if not ok_rf or not ReaderFont then
    return
end

local ok_ev, Event = pcall(require, "ui/event")
if not ok_ev then Event = nil end

local orig_fallback_fonts = CreDocument.fallback_fonts
if type(orig_fallback_fonts) ~= "table" then
    orig_fallback_fonts = {}
end

local NUM_SLOTS = 5

local function k_enabled()
    return "my_fallback_fonts"
end

local function k_slot(i)
    return ("my_fallback_font_%d"):format(i)
end

local function uniq(list)
    local seen, out = {}, {}
    for _, v in ipairs(list or {}) do
        if type(v) == "string" and v ~= "" and not seen[v] then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    return out
end

local function get_settings()
    if type(G_reader_settings) == "table" then
        return G_reader_settings
    end
    return nil
end

local function build_my_fallbacks(self)
    local ds = get_settings()
    local orig_copy = { unpack(orig_fallback_fonts) }

    if not ds then
        return orig_copy
    end

    local combined = {}
    for i = 1, NUM_SLOTS do
        local v = ds:readSetting(k_slot(i))
        if type(v) == "string" and v ~= "" then
            combined[#combined + 1] = v
        end
    end
    for _, v in ipairs(orig_copy) do
        combined[#combined + 1] = v
    end

    return uniq(combined)
end

local function apply_fallbacks(self)
    local ds = get_settings()
    if not (self and ds) then
        return
    end

    if ds:isTrue(k_enabled()) then
        CreDocument.fallback_fonts = build_my_fallbacks(self)
    else
        CreDocument.fallback_fonts = orig_fallback_fonts
    end

    if self.ui and self.ui.document and self.ui.document.setupFallbackFontFaces then
        self.ui.document:setupFallbackFontFaces()
    end

    if Event and self.ui and self.ui.handleEvent then
        self.ui:handleEvent(Event:new("UpdatePos"))
    end
end

local function collect_native_font_items(self)
    local items = {}
    local seen = {}

    if type(self.face_table) ~= "table" then
        return items
    end

    for _, it in ipairs(self.face_table) do
        if type(it) == "table" then
            local v = it.menu_item_id
            if type(v) == "string" and v ~= ""
               and type(it.text_func) == "function"
               and not seen[v] then
                seen[v] = true
                items[#items + 1] = it
            end
        end
    end

    return items
end

local function label_for_value(self, v)
    if type(v) ~= "string" or v == "" then
        return _("(none)")
    end

    local cache = self._native_font_items_cache or {}
    for _, it in ipairs(cache) do
        if it.menu_item_id == v then
            local ok, txt = pcall(it.text_func)
            if ok and type(txt) == "string" and txt ~= "" then
                return txt
            end
            break
        end
    end

    return v
end

local function make_slot_submenu(self, slot)
    local ds = get_settings()
    local fonts = self._native_font_items_cache or {}
    local items = {}

    if not ds then
        items[#items + 1] = {
            text = _("(no settings backend)"),
            callback = function() end,
            keep_menu_open = true,
        }
        return items
    end

    items[#items + 1] = {
        text = _("(none)"),
        checked_func = function()
            local v = ds:readSetting(k_slot(slot))
            return type(v) ~= "string" or v == ""
        end,
        callback = function()
            ds:delSetting(k_slot(slot))
            apply_fallbacks(self)
        end,
        keep_menu_open = true,
    }

    if #fonts == 0 then
        items[#items + 1] = {
            text = _("(font list not available)"),
            callback = function() end,
            keep_menu_open = true,
        }
        return items
    end

    for _, it in ipairs(fonts) do
        local v = it.menu_item_id
        items[#items + 1] = {
            text_func = it.text_func,
            checked_func = function()
                return ds:readSetting(k_slot(slot)) == v
            end,
            callback = function()
                ds:saveSetting(k_slot(slot), v)
                if not ds:isTrue(k_enabled()) then
                    ds:saveSetting(k_enabled(), true)
                end
                apply_fallbacks(self)
            end,
            keep_menu_open = true,
        }
    end

    return items
end

local function make_root_submenu(self)
    local ds = get_settings()
    if not ds then
        return {
            {
                text = _("(no settings backend)"),
                callback = function() end,
                keep_menu_open = true,
            },
        }
    end

    local menu = {
        {
            text = _("Enable extra fallback fonts"),
            checked_func = function()
                return ds:isTrue(k_enabled())
            end,
            callback = function()
                ds:saveSetting(k_enabled(), not ds:isTrue(k_enabled()))
                apply_fallbacks(self)
            end,
            keep_menu_open = true,
        },
    }

    local slot_labels = {
        _("Fallback #1: "),
        _("Fallback #2: "),
        _("Fallback #3: "),
        _("Fallback #4: "),
        _("Fallback #5: "),
    }

    for i = 1, NUM_SLOTS do
        local slot = i
        menu[#menu + 1] = {
            text_func = function()
                return slot_labels[slot] .. label_for_value(self, ds:readSetting(k_slot(slot)))
            end,
            sub_item_table_func = function()
                return make_slot_submenu(self, slot)
            end,
        }
    end

    menu[#menu + 1] = {
        text = _("Clear all extra fallbacks"),
        callback = function()
            for i = 1, NUM_SLOTS do
                ds:delSetting(k_slot(i))
            end
            apply_fallbacks(self)
        end,
        keep_menu_open = true,
    }

    return menu
end

local orig_setup = ReaderFont.setupFaceMenuTable
ReaderFont.setupFaceMenuTable = function(self)
    orig_setup(self)

    self._native_font_items_cache = collect_native_font_items(self)

    if self._extra_fallback_menu_added then
        return
    end
    self._extra_fallback_menu_added = true

    if type(self.face_table) ~= "table" then
        return
    end

    table.insert(self.face_table, 1, {
        text = _("Extra fallback fonts\226\128\166"),
        sub_item_table_func = function()
            return make_root_submenu(self)
        end,
    })
end

local orig_onReadSettings = ReaderFont.onReadSettings
ReaderFont.onReadSettings = function(self, config)
    local r = orig_onReadSettings(self, config)
    apply_fallbacks(self)
    return r
end
