-- Text box editor. Opened by Game/game_creative.lua (begin_text_box) when you
-- L-click with base's text ent (bent_base_txt) in the hotbar.
--
-- Hand-off (windows can't call game code): the message goes into
-- temp.creative.text_msg and temp.creative.text_state becomes "commit" (place)
-- or "cancel"; game_creative's tick then places the ent at the spot you aimed.
--
-- Colour codes are the ones FBW text boxes understand: ^xRRGGBB switches the
-- colour, ^! switches back to normal. The swatches append a code at the end
-- of the text; codes can also be typed by hand.
--
-- Everything is drawn and hit-tested in the "inner" coord mode (the one the
-- engine uses for window widgets), set at the start of every entry point.

local MSG_VAR   = "temp.creative.text_msg"
local STATE_VAR = "temp.creative.text_state"

local BOX_X0, BOX_X1, BOX_Y0, BOX_Y1 = 0.06, 0.94, 0.60, 0.86   -- editor
local PRE_X0, PRE_X1, PRE_Y0, PRE_Y1 = 0.06, 0.94, 0.10, 0.37   -- preview
local CW, CH, LINE_H = 0.0125, 0.025, 0.031                      -- editor/preview font

-- "Normal" (no colour code / after ^!) = the colour the game's text box draws
-- plain text in: ^x007f7f (teal; measured in game, 2026-11-15).
local DEFAULT_COL = { 0.0, 127 / 255, 127 / 255 }

local SWATCHES = {
    { name = "Normal", code = "^!" },
    { name = "White",  code = "^xffffff" },
    { name = "Gray",   code = "^xa0a0a0" },
    { name = "Red",    code = "^xff3030" },
    { name = "Orange", code = "^xff9020" },
    { name = "Yellow", code = "^xffff00" },
    { name = "Green",  code = "^x40ff40" },
    { name = "Cyan",   code = "^x00ffff" },
    { name = "Blue",   code = "^x4080ff" },
    { name = "Purple", code = "^xb060ff" },
    { name = "Pink",   code = "^xff60c0" },
    { name = "Brown",  code = "^xa06030" },
}
local SW_Y0, SW_H, SW_W, SW_GAP = 0.485, 0.045, 0.060, 0.0133

-- action buttons: id, label, x0, y0, w, h
local BUTTONS = {
    { id = "paste",  label = "PASTE",               x = 0.06, y = 0.415, w = 0.13, h = 0.040 },
    { id = "clear",  label = "CLEAR",               x = 0.20, y = 0.415, w = 0.13, h = 0.040 },
    { id = "place",  label = "PLACE TEXT BOX (CTRL+ENTER)", x = 0.20, y = 0.025, w = 0.34, h = 0.050 },
    { id = "cancel", label = "CANCEL (ESC)",        x = 0.56, y = 0.025, w = 0.24, h = 0.050 },
}

local started = false

local function inner(wid)
    pcall(ga_win_set_screen_coord_mode, wid, "inner")
end

local function hit(c, x, y, w, h)
    return c ~= nil and c.x >= x and c.x <= x + w and c.y >= y and c.y <= y + h
end

local function swatch_rect(i)
    return BOX_X0 + (i - 1) * (SW_W + SW_GAP), SW_Y0, SW_W, SW_H
end

local function hex_col(code)
    local h = string.match(code, "^%^x(%x%x%x%x%x%x)$")
    if h == nil then return DEFAULT_COL end
    return { tonumber(string.sub(h, 1, 2), 16) / 255,
             tonumber(string.sub(h, 3, 4), 16) / 255,
             tonumber(string.sub(h, 5, 6), 16) / 255 }
end

-------------------------------------------------------------------------------
-- Preview: the message as the text box shows it (colours applied, codes hidden),
-- word-wrapped to the preview box.
-------------------------------------------------------------------------------

-- msg -> paragraphs, each a list of cells { ch, col }
local function parse(msg)
    local paras, cur, col = {}, {}, DEFAULT_COL
    local i, n = 1, #msg
    while i <= n do
        local c = string.sub(msg, i, i)
        if c == "^" and string.match(string.sub(msg, i, i + 7), "^%^x%x%x%x%x%x%x$") then
            col = hex_col(string.sub(msg, i, i + 7))
            i = i + 8
        elseif c == "^" and string.sub(msg, i + 1, i + 1) == "!" then
            col = DEFAULT_COL
            i = i + 2
        elseif c == "\n" then
            paras[#paras + 1] = cur
            cur = {}
            i = i + 1
        elseif c == "\r" then
            i = i + 1
        else
            cur[#cur + 1] = { ch = c, col = col }
            i = i + 1
        end
    end
    paras[#paras + 1] = cur
    return paras
end

-- wrap one paragraph at max columns, breaking at the last space if possible
local function wrap(cells, maxc, out)
    if #cells == 0 then out[#out + 1] = {} return end
    local s = 1
    while s <= #cells do
        local e = s + maxc - 1
        if e >= #cells then
            local line = {}
            for k = s, #cells do line[#line + 1] = cells[k] end
            out[#out + 1] = line
            return
        end
        local brk = nil
        for k = e + 1, s + math.floor(maxc / 2), -1 do
            if cells[k] and cells[k].ch == " " then brk = k break end
        end
        local line = {}
        local last = brk and (brk - 1) or e
        for k = s, last do line[#line + 1] = cells[k] end
        out[#out + 1] = line
        s = brk and (brk + 1) or (e + 1)
    end
end

local function render_preview(wid, msg)
    ga_win_quad_color(wid, PRE_X0 - 0.008, PRE_Y0 - 0.008, PRE_X1 + 0.008, PRE_Y1 + 0.008, std.vec(0.10, 0.10, 0.13))
    ga_win_set_char_size(wid, CW, CH)
    local maxc = math.floor((PRE_X1 - PRE_X0) / CW)
    local lines = {}
    for _, para in ipairs(parse(msg)) do wrap(para, maxc, lines) end
    local max_lines = math.floor((PRE_Y1 - PRE_Y0) / LINE_H)
    for li = 1, math.min(#lines, max_lines) do
        local y = PRE_Y1 - li * LINE_H + (LINE_H - CH) * 0.5
        local line = lines[li]
        local k = 1
        while k <= #line do
            local col = line[k].col
            local j = k
            local parts = {}
            while j <= #line and line[j].col == col do
                parts[#parts + 1] = line[j].ch
                j = j + 1
            end
            ga_win_set_front_color(wid, std.vec(col[1], col[2], col[3]))
            ga_win_txt(wid, PRE_X0 + (k - 1) * CW, y, table.concat(parts))
            k = j
        end
    end
    ga_win_set_front_color_default(wid)
    if #lines > max_lines then
        ga_win_set_char_size(wid, 0.009, 0.018)
        ga_win_txt(wid, PRE_X1 - 0.30, PRE_Y0 - 0.004, "(" .. (#lines - max_lines) .. " more lines)")
    end
end

-------------------------------------------------------------------------------
-- Window entry points
-------------------------------------------------------------------------------

local function get_text(wid)
    local ok, s = pcall(ga_win_widget_mutable_text_box_get_text, wid)
    if ok and type(s) == "string" then return s end
    return ""
end

local function set_text(wid, s)
    pcall(ga_win_widget_mutable_text_box_set_text, wid, s)
end

local function start(wid)
    if started then return end
    started = true
    inner(wid)
    ga_init_s(MSG_VAR, "")
    ga_init_s(STATE_VAR, "edit")
    pcall(ga_win_show_cursor_icon, true)
    ga_win_widget_mutable_text_box_start(wid, BOX_X0, BOX_X1, BOX_Y0, BOX_Y1, CW, CH,
        std.vec(0.0, 0.5, 0.5), ga_get_s(MSG_VAR))
end

local function finish(wid)
    if not started then return end
    started = false
    -- keep the text as the draft / next text box's starting text
    ga_set_s(MSG_VAR, get_text(wid))
    -- closed any other way than PLACE = cancelled
    if ga_get_s(STATE_VAR) == "edit" then ga_set_s(STATE_VAR, "cancel") end
    ga_win_widget_mutable_text_box_end(wid)
end

function p.__start(wid)    start(wid) end
function p.__on_start(wid) start(wid) end
function p.__end(wid)      finish(wid) end
function p.__on_end(wid)   finish(wid) end

local function close(wid, state)
    local s = get_text(wid)
    if state == "commit" then
        s = (string.gsub(s, "%s+$", ""))        -- Ctrl+Enter's newline, trailing blanks
        set_text(wid, s)
        if s == "" then
            ga_hud_msg("Type a message first (or ESC to cancel)", 1.5)
            return
        end
    end
    ga_set_s(MSG_VAR, s)
    ga_set_s(STATE_VAR, state)
    ga_play_sound("menu_select")
    ga_window_pop()
end

function p.__process_input(wid)
    inner(wid)
    if ga_win_key_pressed(wid, "ESC") then close(wid, "cancel") return end
    if ga_win_key_pressed(wid, "ENTER") and ga_win_key_down("LCTRL") then
        close(wid, "commit")
        return
    end
    if not ga_win_mouse_pressed(wid, true) then return end
    local c = ga_win_get_cursor_pos(wid)

    for i, sw in ipairs(SWATCHES) do
        local x, y, w, h = swatch_rect(i)
        if hit(c, x, y, w, h) then
            set_text(wid, get_text(wid) .. sw.code)
            ga_play_sound("menu_select")
            return
        end
    end
    for _, b in ipairs(BUTTONS) do
        if hit(c, b.x, b.y, b.w, b.h) then
            if b.id == "place" then close(wid, "commit")
            elseif b.id == "cancel" then close(wid, "cancel")
            elseif b.id == "paste" then
                local ok, clip = pcall(ga_paste_from_clipboard)
                if ok and type(clip) == "string" then set_text(wid, get_text(wid) .. clip) end
                ga_play_sound("menu_select")
            elseif b.id == "clear" then
                set_text(wid, "")
                ga_play_sound("menu_select")
            end
            return
        end
    end
end

function p.__render(wid)
    inner(wid)
    ga_win_set_background(wid, std.vec(0.0, 0.0, 0.0), 0.95)
    local c = ga_win_get_cursor_pos(wid)

    ga_win_set_char_size(wid, 0.016, 0.032)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt_center(wid, 0.935, "TEXT BOX")
    ga_win_set_char_size(wid, 0.0085, 0.017)
    ga_win_set_front_color(wid, std.vec(0.75, 0.75, 0.75))
    ga_win_txt_center(wid, 0.895, "Type the message (Enter = new line). People read it with F.")
    ga_win_set_front_color_default(wid)
    -- the editor (mutable text box widget) is drawn by the engine itself

    -- colour swatches
    ga_win_set_char_size(wid, 0.0085, 0.017)
    ga_win_txt(wid, BOX_X0, SW_Y0 + SW_H + 0.012,
        "COLOR (adds a code at the end):   any color = ^x + 6 hex digits, e.g. ^xff8800   ^! = normal")
    local hover_code = nil
    for i, sw in ipairs(SWATCHES) do
        local x, y, w, h = swatch_rect(i)
        local hov = hit(c, x, y, w, h)
        if hov then hover_code = sw.name .. "  " .. sw.code end
        local col = (sw.code == "^!") and DEFAULT_COL or hex_col(sw.code)
        local f = hov and 0.005 or 0.002
        ga_win_quad_color(wid, x - f, y - f, x + w + f, y + h + f,
            hov and std.vec(1.0, 1.0, 1.0) or std.vec(0.35, 0.35, 0.35))
        ga_win_quad_color(wid, x, y, x + w, y + h, std.vec(col[1], col[2], col[3]))
        if sw.code == "^!" then
            ga_win_set_char_size(wid, 0.0075, 0.015)
            ga_win_set_front_color(wid, std.vec(0.0, 0.0, 0.0))
            ga_win_txt(wid, x + (w - 4 * 0.0075) * 0.5, y + (h - 0.015) * 0.5, "NORM")
            ga_win_set_front_color_default(wid)
        end
    end
    if hover_code then                            -- name + code of the hovered swatch
        ga_win_set_char_size(wid, 0.0085, 0.017)
        ga_win_txt(wid, 0.36, 0.425, hover_code)
    end

    -- buttons
    for _, b in ipairs(BUTTONS) do
        local hov = hit(c, b.x, b.y, b.w, b.h)
        local base = (b.id == "place") and { 0.15, 0.40, 0.18 } or { 0.20, 0.22, 0.30 }
        local k = hov and 1.6 or 1.0
        ga_win_quad_color(wid, b.x - 0.002, b.y - 0.002, b.x + b.w + 0.002, b.y + b.h + 0.002, std.vec(0.5, 0.5, 0.55))
        ga_win_quad_color(wid, b.x, b.y, b.x + b.w, b.y + b.h,
            std.vec(math.min(1, base[1] * k), math.min(1, base[2] * k), math.min(1, base[3] * k)))
        local cw, ch = 0.0095, 0.019
        ga_win_set_char_size(wid, cw, ch)
        ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
        ga_win_txt(wid, b.x + (b.w - #b.label * cw) * 0.5, b.y + (b.h - ch) * 0.5, b.label)
        ga_win_set_front_color_default(wid)
    end

    -- preview
    ga_win_set_char_size(wid, 0.0085, 0.017)
    ga_win_txt(wid, PRE_X0, PRE_Y1 + 0.014, "PREVIEW (how the text box shows it):")
    render_preview(wid, get_text(wid))
end
