-- page-footnotes-only.lua
-- Всплывающий попап ТОЛЬКО по той сноске, на чей маркер тапнули (вид "как словарь").
-- Style tweaks -> ВЫКЛЮЧИ все "сноски ... на странице".
-- Настройка "показывать сноски во всплывающем окне" НЕ нужна (работает в любом положении).
local logger          = require("logger")
local Font            = require("ui/font")
local UIManager       = require("ui/uimanager")
local Geom            = require("ui/geometry")
local Blitbuffer      = require("ffi/blitbuffer")
local InputContainer  = require("ui/widget/container/inputcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")

local TAG = "[page-footnotes-only]"

local ENABLED, FONT_FACE, FONT_SIZE, PAD, MAX_CHARS = true, "cfont", 18, 10, 2500

local ok_cre, CreDocument = pcall(require, "document/credocument")
if not ok_cre or not CreDocument or not ENABLED then return end
local ok_rl, ReaderLink = pcall(require, "apps/reader/modules/readerlink")
if not ok_rl or not ReaderLink then return end

local current_popup = nil
local show_popup    -- forward

local function footnote_flags(trust)
    local f = 0x0004+0x0008+0x0010+0x0020+0x0040+0x0100+0x0200+0x0400+0x0800+0x1000+0x4000+0x8000
    if trust then f = f + 0x0002 end
    return f
end
local function clean_text(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("\173", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if #s > MAX_CHARS then s = s:sub(1, MAX_CHARS) .. "…" end
    return s ~= "" and s or nil
end
local function get_face()
    local ok, f = pcall(Font.getFace, Font, FONT_FACE, FONT_SIZE)
    if ok and f then return f end
    ok, f = pcall(Font.getFace, Font, "ffont", FONT_SIZE)
    return (ok and f) or nil
end
local function sz(w)
    local ok, r1, r2 = pcall(w.getSize, w)
    if not ok then return 0, 0 end
    if type(r1) == "table" then return r1.w or 0, r1.h or 0 end
    if type(r2) == "number" then return r1 or 0, r2 or 0 end
    return r1 or 0, 0
end
local function measure_h(text, width, face)
    local ok, w = pcall(TextBoxWidget.new, TextBoxWidget, { text = text, face = face, width = width })
    if not ok or not w then return 0 end
    local _, h = sz(w); if w.free then pcall(w.free, w) end; return h or 0
end
local function tw(text, face) return TextWidget:new({ text = text, face = face }) end

local function paginate(full, width, face, max_h)
    if not full or full == "" then return { "" } end
    if measure_h(full, width, face) <= max_h then return { full } end
    local words, pages, cur, n = {}, {}, {}, 0
    for wd in full:gmatch("%S+") do words[#words + 1] = wd end
    local function ct() return table.concat(cur, " ") end
    for i, wd in ipairs(words) do
        cur[#cur + 1] = wd; n = n + 1
        if n % 6 == 0 or i == #words then
            if measure_h(ct(), width, face) > max_h and #cur > 1 then
                while #cur > 1 do cur[#cur] = nil; if measure_h(ct(), width, face) <= max_h then break end end
                pages[#pages + 1] = ct(); cur = { wd }
            end
        end
    end
    if #cur > 0 then pages[#pages + 1] = ct() end
    if #pages == 0 then pages[1] = full end
    return pages
end
local function plain_text(doc, target, extS, extE)
    local raw
    if extS and extE then
        local ok, t = pcall(doc.getTextFromXPointers, doc, extS, extE, true)
        if ok and type(t) == "string" then raw = t end
    end
    if not raw then
        local ok, t = pcall(doc.getTextFromXPointer, doc, target, true)
        if ok and type(t) == "string" then raw = t end
    end
    return clean_text(raw)
end
local function close_popup()
    if not current_popup then return end
    local w, ui = current_popup.widget, current_popup.ui
    current_popup = nil
    if w then pcall(UIManager.close, UIManager, w) end
    if ui then pcall(function() UIManager:setDirty(ui, "full") end) end
end

-- Единый разбор зон: крестик / стрелки / тап вне / свайп. Вызывается и контейнером, и ReaderUI.
local function handle_popup_ges(ges)
    if not ges or not current_popup then return false end
    local p = current_popup
    local ui = p.ui
    if ges.ges == "swipe" then close_popup(); return true end
    if ges.ges ~= "tap" then return false end
    local pos = ges.pos
    if not pos or not pos.x then return false end
    local X, Y = pos.x, pos.y
    local function inr(z) return X >= z.x and X <= z.x + z.w and Y >= z.y and Y <= z.y + z.h end
    if inr(p.zones.close) then close_popup(); return true end
    if inr(p.zones.left)  and p.idx > 1   then local i = p.idx - 1; pcall(close_popup); pcall(show_popup, ui, p.text, i); return true end
    if inr(p.zones.right) and p.idx < p.n then local i = p.idx + 1; pcall(close_popup); pcall(show_popup, ui, p.text, i); return true end
    if inr(p.rect) then return true end   -- тап по тексту сноски: читать, не закрывать
    close_popup(); return true             -- тап вне окна: закрыть
end

local function build_and_show(ui)
    local p = current_popup
    local face = get_face()
    if not face then return false end
    local dimen = ui and ui.dimen
    if not dimen then return false end
    local SW, SH = dimen.w, dimen.h
    local BW = math.max(40, math.min(SW - 2*(1+PAD) - 16, 760))
    local max_h = math.max(40, math.floor(SH*0.55))
    local pages = paginate(p.text, BW, face, max_h)
    p.n = #pages
    if p.idx < 1 then p.idx = 1 end; if p.idx > p.n then p.idx = p.n end

    local body  = TextBoxWidget:new({ text = pages[p.idx], face = face, width = BW })
    local title = tw("Сноска", face)
    local xw    = tw("[x]", face)
    local lw    = tw("<--  ", face)
    local rw    = tw("  -->", face)
    local ctr   = tw(p.idx .. " / " .. p.n, face)
    local title_w, title_h = sz(title); local x_w, x_h = sz(xw)
    local l_w, l_h = sz(lw); local r_w, r_h = sz(rw); local c_w, c_h = sz(ctr)
    local _, body_h = sz(body)

    local span_hdr = math.max(0, BW - title_w - x_w)
    local header = HorizontalGroup:new({ title, HorizontalSpan:new({ width = span_hdr }), xw })
    local header_h = math.max(1, title_h, x_h)
    local rest = math.max(0, BW - l_w - r_w - c_w); local s1 = math.floor(rest/2); local s2 = math.max(0, rest - s1)
    local nav = HorizontalGroup:new({ lw, HorizontalSpan:new({ width = s1 }), ctr, HorizontalSpan:new({ width = s2 }), rw })
    local nav_h = math.max(1, l_h, r_h, c_h)
    local vgroup = VerticalGroup:new({ header, VerticalSpan:new({ width = 4 }), body, VerticalSpan:new({ width = 4 }), nav })
    local frame = FrameContainer:new({ bordersize = 1, margin = 0, padding = PAD, background = Blitbuffer.COLOR_WHITE, vgroup })
    local frame_w = BW + 2*(1+PAD)
    local frame_h = math.max(1, header_h + 4 + body_h + 4 + nav_h + 2*(1+PAD))
    local px = math.floor((SW - frame_w)/2)
    local py = math.floor((SH - frame_h)/2)

    local OX, OY = px + 1 + PAD, py + 1 + PAD
    local nav_y = OY + header_h + 4 + body_h + 4
    p.zones = {
        close = { x = OX + (BW - x_w), y = OY,    w = math.max(1, x_w), h = math.max(1, x_h) },
        left  = { x = OX,              y = nav_y, w = math.max(1, l_w), h = math.max(1, nav_h) },
        right = { x = OX + (BW - r_w), y = nav_y, w = math.max(1, r_w), h = math.max(1, nav_h) },
    }
    p.rect = { x = px, y = py, w = frame_w, h = frame_h }

    local cont = InputContainer:new({
        dimen = Geom:new({ x = 0, y = 0, w = SW, h = SH }),
        covers_fullscreen = true,
        is_always_active = true,
    })
    cont[1] = CenterContainer:new({ dimen = Geom:new({ x = 0, y = 0, w = SW, h = SH }), frame })

    -- дублируем маршруты, чтобы поймать жест на любом слое диспетчера
    cont.onTap     = function(_, arg) return handle_popup_ges(arg and arg.ges) end
    cont.onGesture = function(_, ev)  return handle_popup_ges(ev) end
    cont.onSwipe   = function(_, arg) return handle_popup_ges(arg and arg.ges) end
    local _he = cont.handleEvent
    cont.handleEvent = function(self, ev)
        if ev and ev.ges then if handle_popup_ges(ev.ges) then return true end end
        if _he then return _he(self, ev) end
        return false
    end
    cont.onClose = function() close_popup(); return true end
    cont.onBack  = function() close_popup(); return true end

    p.widget = cont
    pcall(UIManager.show, UIManager, cont)
    pcall(function() UIManager:setDirty(cont, "full") end)
    return true
end

show_popup = function(ui, text, idx)
    pcall(close_popup)
    current_popup = { ui = ui, text = text, idx = idx or 1 }
    return build_and_show(ui)
end

local function try_show(self, target, src)
    if type(target) ~= "string" or target == "" then return false end
    local trust = type(src) == "string" and src ~= ""
    local doc = self and self.ui and self.ui.document
    if not (doc and doc.isLinkToFootnote) then return false end
    local ok2, is_fn, _, _, extS, extE = pcall(doc.isLinkToFootnote, doc, src or "", target, footnote_flags(trust), 10000)
    if not (ok2 and is_fn) then return false end
    local txt = plain_text(doc, target, extS, extE)
    if not txt then return false end
    return pcall(show_popup, self.ui, txt)
end

local function extract(link)
    if type(link) == "table" then
        return (link.section or link.uri or link.link or link.xpointer), link.a_xpointer
    elseif type(link) == "string" then
        return link, nil
    end
    return nil, nil
end

-- popup-настройка ВКЛ: KOReader сам зовёт showAsFootnotePopup
if type(ReaderLink.showAsFootnotePopup) == "function" then
    local orig = ReaderLink.showAsFootnotePopup
    ReaderLink.showAsFootnotePopup = function(self, link, ...)
        local t, s = extract(link)
        if try_show(self, t, s) then return true end
        return orig(self, link, ...)
    end
end

-- popup-настройка ВЫКЛ: тап идёт в переход по ссылке -- перехватываем здесь
local hooked_goto = {}
for _, nm in ipairs({ "onGotoLink", "onGoToLink", "goToLink", "gotoLink" }) do
    if type(ReaderLink[nm]) == "function" and not hooked_goto[nm] then
        local orig = ReaderLink[nm]
        ReaderLink[nm] = function(self, link, ...)
            local t, s = extract(link)
            if try_show(self, t, s) then return true end   -- сноска: свой попап вместо перехода
            return orig(self, link, ...)                    -- обычная ссылка: штатный переход
        end
        hooked_goto[nm] = true
    end
end

-- страховка/основной путь закрытия на PB: разбор зон прямо в хуке ReaderUI
local ok_ru, ReaderUI = pcall(require, "apps/reader/readerui")
if ok_ru and ReaderUI and type(ReaderUI.onGesture) == "function" then
    local orig_ges = ReaderUI.onGesture
    ReaderUI.onGesture = function(self, ev)
        if current_popup then
            if handle_popup_ges(ev) then return true end
        end
        return orig_ges(self, ev)
    end
end

logger.info(TAG .. ": loaded")
