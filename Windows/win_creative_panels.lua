-- Creative menu: the WEAPONS, ITEMS and BUFFS tabs, plus click-to-type
-- amounts (num_field). See win_creative_core.lua for how the files share things.
creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

-------------------------------------------------------------------------------
-- Inline number editing: click an amount (ITEMS values, weapon ammo/upgrade
-- level) and type an exact value. Enter or a click elsewhere applies it,
-- Esc cancels. The engine gives a window only ONE text input widget (that is
-- the search box), so this field reads the digit keys itself. The clickable
-- rects are recorded while rendering (num_field) and hit-tested next frame.
-------------------------------------------------------------------------------

local num_targets = {}   -- this frame's amounts: { key, x0, y0, x1, y1, tx, cw, len, value, apply, neg }
-- { key, text, pos, fresh, apply, on_enter, neg }: pos = caret (0 = before
-- the 1st char, #text = after the last), fresh = whole text "selected"
-- (typing replaces it, Left / Right / Home / End drop the selection)
local num_edit    = nil
local num_blink   = 0
local num_last_click = nil   -- { key, time }: a 2nd click on the same field soon after = select all
local DOUBLE_CLICK = 0.35    -- seconds
local NUM_DIGITS  = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
local NUM_MAX_LEN = 10   -- digits (a leading "-" comes on top)
local NUM_MAX     = 2147483647
local TXT_MAX_LEN = 64   -- text fields (opts.text): bent text params like a green key combo

-- text fields: window key name -> char, char with Shift (US layout). Only
-- names from the window key table (FBW.exe StringToDKEY); anything else is a
-- HARD USER ERROR that quits the game.
local TEXT_KEYS = {
    { "SPACE", " " }, { "MINUS", "-", "_" }, { "EQUALS", "=", "+" }, { "PERIOD", "." },
    { "COMMA", "," }, { "SLASH", "/" }, { "SEMICOLON", ";", ":" }, { "QUOTE", "'" },
    { "LBRACKET", "[" }, { "RBRACKET", "]" }, { "BACKSLASH", "\\" }, { "GRAVE", "`" },
}
for i = 0, 9 do TEXT_KEYS[#TEXT_KEYS + 1] = { tostring(i), tostring(i) } end
for c = string.byte("A"), string.byte("Z") do
    local k = string.char(c)
    TEXT_KEYS[#TEXT_KEYS + 1] = { k, string.lower(k), k }
end

local function num_edit_cancel() num_edit = nil end

function C.num_edit_commit()
    local e = num_edit
    num_edit = nil
    if e == nil then return end
    if e.text_mode then                      -- text field: any string, "" included
        e.apply(e.text)
        ga_play_sound("menu_select")
        return
    end
    local n = tonumber(e.text)
    if n == nil then n = e.empty end         -- emptied (or just "-"): the field's opts.empty,
    if n == nil then return end              -- else leave the value alone
    if n > NUM_MAX then n = NUM_MAX end
    if n < -NUM_MAX then n = -NUM_MAX end
    if n < 0 and not e.neg then n = 0 end
    e.apply(math.floor(n))
    ga_play_sound("menu_select")
end

-- Open a field from code (the INTERACT amount pickups open theirs when picked).
-- The value starts "selected", so typing replaces it (arrow keys drop the
-- selection to edit it instead). on_enter() runs after Enter applied the
-- value (not on a click elsewhere / Esc); it may close the window. neg = the
-- "-" key may make it negative. text_mode = a text field (letters, digits,
-- punctuation; apply gets the string).
function C.num_edit_open(key, value, apply, on_enter, neg, text_mode)
    local text = tostring(value)
    num_edit = { key = key, text = text, pos = #text, fresh = true, apply = apply,
                 on_enter = on_enter, neg = neg == true, text_mode = text_mode == true }
    num_blink = 0
end

-- typing replaces a selected text; returns the text left / right of the caret
local function edit_split(e)
    if e.fresh then e.text = ""; e.pos = 0; e.fresh = false end
    if e.pos > #e.text then e.pos = #e.text end
    if e.pos < 0 then e.pos = 0 end
    return string.sub(e.text, 1, e.pos), string.sub(e.text, e.pos + 1)
end

local function edit_insert(e, str)
    local l, r = edit_split(e)
    e.text = l .. str .. r
    e.pos = e.pos + #str
    num_blink = 0
end

-- typing into a text field
local function text_edit_keys(wid, e)
    if ga_win_key_down("LCTRL") or ga_win_key_down("RCTRL") then return end   -- Ctrl+key = no char
    local shift = ga_win_key_down("LSHIFT") or ga_win_key_down("RSHIFT")
    for _, t in ipairs(TEXT_KEYS) do
        if ga_win_key_pressed(wid, t[1]) then
            if e.fresh or #e.text < TXT_MAX_LEN then edit_insert(e, (shift and t[3]) or t[2]) end
        end
    end
end

-- typing a digit into a number field (at the caret, never left of a "-")
local function digit_edit_key(e, k)
    if e.fresh then e.text = ""; e.pos = 0; e.fresh = false end
    local neg = string.sub(e.text, 1, 1) == "-"
    if neg and e.pos < 1 then e.pos = 1 end
    local body = neg and string.sub(e.text, 2) or e.text
    if body == "0" then                        -- a lone 0 is replaced, not prefixed
        e.text = neg and "-" or ""
        e.pos = #e.text
        body = ""
    end
    if #body < NUM_MAX_LEN then edit_insert(e, k) end
end

-- Keyboard while a field is open. Returns true if a field was open (its keys
-- must then not reach the search box / Esc-closes-window / Tab), and true as
-- a 2nd value when Enter's on_enter ran (the window may be gone: stop there).
-- Left / Right / Home / End move the caret, Backspace / Delete remove the
-- char before / after it, Ctrl+A (or a double click) selects everything.
function C.num_edit_keys(wid)
    local e = num_edit
    if e == nil then return false end
    if e.pos == nil or e.pos > #e.text then e.pos = #e.text end
    if ga_win_key_pressed(wid, "ESC") then num_edit_cancel() return true end
    if ga_win_key_pressed(wid, "ENTER") then
        C.num_edit_commit()
        if e.on_enter then e.on_enter() return true, true end
        return true
    end
    local ctrl = ga_win_key_down("LCTRL") or ga_win_key_down("RCTRL")
    if ctrl and ga_win_key_pressed(wid, "A") then
        e.fresh = (#e.text > 0); e.pos = #e.text; num_blink = 0
        return true                            -- no "a" typed into a text field
    end

    -- caret movement (a selection collapses to its start / end first)
    if ga_win_key_pressed_or_spammed(wid, "LEFT", 0.4, 0.04) then
        if e.fresh then e.pos = 0 elseif e.pos > 0 then e.pos = e.pos - 1 end
        e.fresh = false; num_blink = 0
    end
    if ga_win_key_pressed_or_spammed(wid, "RIGHT", 0.4, 0.04) then
        if e.fresh then e.pos = #e.text elseif e.pos < #e.text then e.pos = e.pos + 1 end
        e.fresh = false; num_blink = 0
    end
    if ga_win_key_pressed(wid, "HOME") then e.pos = 0; e.fresh = false; num_blink = 0 end
    if ga_win_key_pressed(wid, "END") then e.pos = #e.text; e.fresh = false; num_blink = 0 end

    if e.text_mode then
        text_edit_keys(wid, e)
    else
        for _, k in ipairs(NUM_DIGITS) do
            if ga_win_key_pressed(wid, k) then digit_edit_key(e, k) end
        end
    end
    -- "-" flips the sign (on a selected / empty / 0 value: start a negative one)
    if e.neg and not e.text_mode and ga_win_key_pressed(wid, "MINUS") then
        if e.fresh or e.text == "" or e.text == "0" then
            e.text = "-"; e.pos = 1
        elseif string.sub(e.text, 1, 1) == "-" then
            e.text = string.sub(e.text, 2); e.pos = math.max(0, e.pos - 1)
        else
            e.text = "-" .. e.text; e.pos = e.pos + 1
        end
        e.fresh = false
        num_blink = 0
    end
    if ga_win_key_pressed_or_spammed(wid, "BACKSPACE", 0.4, 0.04) then
        if e.fresh then
            edit_split(e)
        elseif e.pos > 0 then
            e.text = string.sub(e.text, 1, e.pos - 1) .. string.sub(e.text, e.pos + 1)
            e.pos = e.pos - 1
        end
        num_blink = 0
    end
    if ga_win_key_pressed_or_spammed(wid, "DELETE", 0.4, 0.04) then
        if e.fresh then
            edit_split(e)
        elseif e.pos < #e.text then
            e.text = string.sub(e.text, 1, e.pos) .. string.sub(e.text, e.pos + 2)
        end
        num_blink = 0
    end
    return true
end

-- caret index for a click at x on target t (nearest gap between two chars)
local function click_pos(t, x)
    if t.cw == nil or t.cw <= 0 then return t.len or 0 end
    local i = math.floor((x - t.tx) / t.cw + 0.5)
    if i < 0 then i = 0 end
    if i > (t.len or 0) then i = t.len or 0 end
    return i
end

-- Left click: open the clicked amount with the caret where you clicked (a
-- double click selects it all), apply the open one when clicking anywhere
-- else. Returns true when the click landed on an amount.
function C.num_edit_click(cursor)
    local hit = nil
    for _, t in ipairs(num_targets) do
        if cursor.x >= t.x0 and cursor.x <= t.x1 and cursor.y >= t.y0 and cursor.y <= t.y1 then hit = t end
    end
    if num_edit ~= nil and (hit == nil or hit.key ~= num_edit.key) then C.num_edit_commit() end
    if hit == nil then num_last_click = nil return false end

    local now = ga_get_sys_f("time.current")
    local double = num_last_click ~= nil and num_last_click.key == hit.key
                   and (now - num_last_click.time) <= DOUBLE_CLICK
    num_last_click = { key = hit.key, time = now }
    if num_edit == nil then
        num_edit = { key = hit.key, text = tostring(hit.value), apply = hit.apply,
                     neg = hit.neg, text_mode = hit.text_mode, empty = hit.empty }
        ga_play_sound("menu_select")
    end
    num_edit.pos = double and #num_edit.text or click_pos(hit, cursor.x)
    num_edit.fresh = double and #num_edit.text > 0
    if double then num_last_click = nil end
    num_blink = 0
    return true
end

-- Draws an amount that turns into a text box when clicked. (x, y) = bottom
-- left of the text (opts.center: x is the centre), cw x ch = char size,
-- opts.max_w shrinks the chars to fit, opts.col = text colour, opts.neg = the
-- "-" key may make it negative. opts.text = a text field (apply gets the
-- string), opts.placeholder = dim text shown while it is empty, opts.min_w =
-- clickable width at least this, opts.empty = number applied when the field
-- is left empty (default: an empty field changes nothing).
-- apply(n) is called with the typed whole number. Returns the width used.
local function num_field(wid, key, x, y, cw, ch, value, apply, opts)
    opts = opts or {}
    local editing = num_edit ~= nil and num_edit.key == key
    local s = editing and num_edit.text or tostring(value)
    local placeholder = (not editing and s == "" and opts.placeholder) or nil
    local shown = placeholder or s
    local n = math.max(#shown, 1) + (editing and 1 or 0)    -- +1 = caret room
    if opts.max_w and n * cw > opts.max_w then
        local k = opts.max_w / (n * cw)
        cw, ch = cw * k, ch * k
    end
    local w = math.max(math.max(n, 2) * cw, opts.min_w or 0)
    if opts.center then x = x - w * 0.5 end
    local px, py = 0.004 / S.aspect, 0.005
    local x0, y0, x1, y1 = x - px, y - py, x + w + px, y + ch + 0.001
    local cursor = ga_win_get_cursor_pos(wid)
    local hov = cursor.x >= x0 and cursor.x <= x1 and cursor.y >= y0 and cursor.y <= y1
    local col = opts.col or std.vec(1.0, 1.0, 1.0)

    if editing then
        local f = 0.002
        ga_win_quad_color(wid, x0 - f / S.aspect, y0 - f, x1 + f / S.aspect, y1 + f, std.vec(1.0, 0.9, 0.3))
        ga_win_quad_color(wid, x0, y0, x1, y1, std.vec(0.02, 0.02, 0.05))
        if num_edit.fresh and #s > 0 then                   -- "selected" look
            ga_win_quad_color(wid, x, y - 0.002, x + #s * cw, y + ch - 0.002, std.vec(0.20, 0.35, 0.65))
        end
    elseif hov then
        ga_win_quad_color(wid, x0, y0, x1, y1, std.vec(0.20, 0.20, 0.30))
    end
    if not editing then                                     -- dotted-ish underline = editable
        ga_win_quad_color(wid, x, y - 0.004, x + math.max(#shown * cw, opts.min_w or 0), y - 0.0025,
            hov and col or std.vec(col.x * 0.45, col.y * 0.45, col.z * 0.45))
    end
    ga_win_set_char_size(wid, cw, ch)
    ga_win_set_front_color(wid, editing and std.vec(1.0, 1.0, 1.0)
        or (placeholder and std.vec(0.45, 0.45, 0.50)) or col)
    ga_win_txt(wid, x, y, shown)
    ga_win_set_front_color_default(wid)
    if editing and (num_blink % 50) < 28 then
        local pos = math.max(0, math.min(num_edit.pos or #s, #s))
        local cx = x + pos * cw + 0.001
        ga_win_quad_color(wid, cx, y - 0.002, cx + 0.0025 / S.aspect, y + ch - 0.002, std.vec(1.0, 0.9, 0.3))
    end

    -- tx / cw / len: where the chars are, so a click can put the caret there
    num_targets[#num_targets + 1] = { key = key, x0 = x0, y0 = y0, x1 = x1, y1 = y1,
                                      tx = x, cw = cw, len = #s,
                                      value = value, apply = apply, neg = opts.neg == true,
                                      text_mode = opts.text == true, empty = opts.empty }
    return x1 - x
end
C.num_field = num_field       -- also used by the INTERACT amount strip (win_creative_lists.lua)

local ITEM_BUTTONS = {
    { section = "GOLD", icon = "icon_gold", var = "xar.player.gold.amount", buttons = {
        { label = "+1K",   delta = 1000 },
        { label = "+10K",  delta = 10000 },
        { label = "+100K", delta = 100000 },
        { label = "Set 0", value = 0 },
        { label = "Max",   value = 1000000 },
    }},
    { section = "HEALTH", icon = "icon_health", var = "xar.player.health.amount", buttons = {
        { label = "+100",  delta = 100 },
        { label = "+1000", delta = 1000 },
        { label = "Set 1", value = 1 },
        { label = "Max",   value = 99999 },
    }},
    { section = "ARMOR", icon = "icon_armor", var = "xar.player.armor.amount", buttons = {
        { label = "+100",  delta = 100 },
        { label = "+1000", delta = 1000 },
        { label = "+10000", delta = 10000 },
        { label = "Set 0", value = 0 },
    }},
    { section = "SHIELD", icon = "icon_shield", var = "xar.player.shield.amount", buttons = {
        { label = "+100",  delta = 100 },
        { label = "+1000", delta = 1000 },
        { label = "+10000", delta = 10000 },
        { label = "Set 0", value = 0 },
    }},
    { section = "XP (total)", icon = "xp", var = "xar.experience.total", buttons = {
        { label = "+1000 XP", delta = 1000 },
        { label = "+10000 XP", delta = 10000 },
    }},
}

-- Icarus mode on / off: the same engine switch as xar's Icarus ent
-- (Windows/win_icarus.lua: ga_get/set_icarus_enabled, no console command)
local function set_icarus(on)
    if ga_set_icarus_enabled == nil then
        ga_hud_msg("Icarus Mode: not in this game version", 2.0)
        return
    end
    ga_set_icarus_enabled(on)
    if on then ga_play_sound("holy_cow") end      -- (what xar's switch plays)
    ga_hud_msg("Icarus Mode " .. (on and "enabled" or "disabled"), 2.0)
end

-- timed = one card per buff: L-click its name = set the timer to the card's
-- seconds (- / + or typed, kept per buff in S.buff_secs), R-click = remove.
-- var = the xar timer (float seconds); all_keys = every ALL_KEY_VARS timer.
local BUFF_BUTTONS = {
    { section = "KEYS", icon = "key_yellow", timed = true, entries = {
        { label = "Yellow Key",    icon = "key_yellow",         var = "xar.key_time.yellow",        secs = 30 },
        { label = "Blue Key",      icon = "key_blue",           var = "xar.key_time.blue",          secs = 30 },
        { label = "Green Key",     icon = "key_green",          var = "xar.key_time.green",         secs = 30 },
        -- icon_bent = use that bent's own texture (what its INTERACT tile shows)
        { label = "Universe Key",  icon = "MonsterKeyUniverse", icon_bent = "bent_key_universe",
          var = "xar.key_time.universe", secs = 30 },
        { label = "Laser Genesis", icon = "key_laser_genesis",  var = "xar.key_time.laser_genesis", secs = 30 },
        { label = "Dan's House",   icon = "key_dans_house",     var = "xar.key_time.dans_house",    secs = 30 },
        { label = "ALL Keys",      icon = "key_yellow",         all_keys = true,                    secs = 60 },
    }},
    { section = "POWERUPS", icon = "icon_damage_5x", timed = true, entries = {
        { label = "5x Damage",     icon = "icon_damage_5x", var = "xar.damage_5x_stacking_time", secs = 30 },
        { label = "Invulnerable",  icon = "icon_invun",     var = "xar.invun_stacking_time",     secs = 30 },
        { label = "5x XP",         icon = "icon_xp_5x",     var = "xar.xp_5x_stacking_time",     secs = 30 },
    }},
    { section = "CHEATS (toggle)", icon = "skull", entries = {
        -- engine console toggles; do NOT ga_set_sys_b metagame.cheat.* (READ ONLY = native crash).
        -- toggle = key into CHEAT_STATE: the button shows ON / OFF and runs
        -- `on` (L-click while off / unknown) or `off` (L-click while on, R-click),
        -- or calls set(true / false) instead when the entry has one.
        { label = "Cheats",    icon = "skull",               toggle = "cheats",
          on = "cheat hodisclosetov;if $metagame.cheat.enabled void (cheat on)", off = "cheat off" },
        { label = "God Mode",  icon = "icon_shield",         toggle = "god",       on = "god on",       off = "god off" },
        { label = "Noclip",    icon = "icon_pacifist",       toggle = "noclip",    on = "noclip on",    off = "noclip off" },
        { label = "ShrinkAny", icon = "icon_shrink_warning", toggle = "shrinkany", on = "shrinkany on", off = "shrinkany off" },
        { label = "Icarus Mode", icon = "icarus",            toggle = "icarus",    set = set_icarus },
        -- hotbar entries: L-click in build mode = touching a pink / blue ring
        -- (game_creative.lua use_path)
        { label = "Pink Path", icon = "ring_pink", path = "pink" },
        { label = "Blue Path", icon = "ring_blue", path = "blue" },
        -- hotbar entries: L-click in build mode runs them (game_creative_place.lua
        -- use_action); labels / icons = C.ACTIONS in win_creative_core.lua
        { label = "Screenshot", icon = "creative_screenshot", action = "screenshot" },
        { label = "Save",       icon = "icon_save",           action = "save" },
        { label = "Respawn",    icon = "respawn_active",      action = "respawn" },
    }},
}

-------------------------------------------------------------------------------
-- Cheat on/off state for the CHEATS buttons.
-- metagame.cheat.enabled / .god are system vars (ga_get_sys_b reads them).
-- metagame.cheat.noclip / .shrink_any are engine env vars that are NOT system
-- vars: ga_get_sys_b on them = engine PoliteExit (the game quits), and ga_get_b
-- only sees "game.globals.<name>". So the console copies them into our own
-- temp int vars (stored by the engine as game.globals.temp.creative.*):
--   set game.globals.temp.creative.st_noclip (if $metagame.cheat.noclip 1 0)
-- (`set` only prints an error for a missing / read-only / wrong-type var, it
-- never quits). The temp var stays -1 (= unknown, shown as "?") if that fails.
-------------------------------------------------------------------------------

local CHEAT_COPY = {
    noclip    = { var = "temp.creative.st_noclip",    engine = "metagame.cheat.noclip" },
    shrinkany = { var = "temp.creative.st_shrinkany", engine = "metagame.cheat.shrink_any" },
}
local CHEAT_POLL_FRAMES = 10
local cheat_poll_wait = 0

local function poll_cheats(force)
    cheat_poll_wait = cheat_poll_wait - 1
    if not force and cheat_poll_wait > 0 then return end
    cheat_poll_wait = CHEAT_POLL_FRAMES
    for _, c in pairs(CHEAT_COPY) do
        if not ga_exists(c.var) then ga_init_i(c.var, -1) end
        ga_command("set game.globals." .. c.var .. " (if $" .. c.engine .. " 1 0)")
    end
end

-- true / false, or nil when unknown
local function cheat_state(key)
    if key == "cheats" then return ga_get_sys_b("metagame.cheat.enabled") == true end
    if key == "god"    then return ga_get_sys_b("metagame.cheat.god") == true end
    if key == "icarus" then
        if ga_get_icarus_enabled == nil then return nil end
        return ga_get_icarus_enabled() == true
    end
    local c = CHEAT_COPY[key]
    if c == nil or not ga_exists(c.var) then return nil end
    local v = ga_get_i(c.var)
    if v == 1 then return true elseif v == 0 then return false end
    return nil
end

local function run_cheat_toggle(e)
    local on = cheat_state(e.toggle)
    if e.set then
        e.set(on ~= true)
    else
        ga_command((on == true) and e.off or e.on)
    end
    poll_cheats(true)       -- re-read right away (the command runs synchronously or by next poll)
end

local ALL_KEY_VARS = {
    "xar.key_time.yellow", "xar.key_time.blue", "xar.key_time.green",
    "xar.key_time.universe", "xar.key_time.laser_genesis", "xar.key_time.dans_house",
}

-- BUFFS layout, one function for render + input:
--   cb("header", section, x, y)        section title (text bottom at y)
--   cb("entry", e, x, y, w, h, timed)  a button / timed card (bottom left x, y)
local BUFF_TOP, TIMED_COLS, TIMED_GAP = 0.78, 3, 0.010
local function buffs_layout(cb)
    local by = BUFF_TOP
    for _, section in ipairs(BUFF_BUTTONS) do
        cb("header", section, 0.03, by)
        by = by - 0.04
        local bw, bh, row, gap = 0.175, 0.030, 0.035, 0.005
        if section.timed then
            bw = (0.94 - TIMED_GAP * (TIMED_COLS - 1)) / TIMED_COLS
            bh, row, gap = 0.034, 0.042, TIMED_GAP
        end
        local bx = 0.03
        for _, e in ipairs(section.entries) do
            if bx + bw > 0.97 + 1e-6 then
                bx = 0.03
                by = by - row
            end
            cb("entry", e, bx, by - bh, bw, bh, section.timed == true)
            bx = bx + bw + gap
        end
        by = by - 0.075 - (section.timed and (bh - 0.030) or 0)
    end
    return by
end

-- a timed card's parts: give (icon + name), minus, value (the seconds), plus
local function timed_parts(x, y, w, h)
    local pw, vw, pad = 0.024, 0.066, 0.004
    local iy, ih = y + pad, h - 2 * pad
    local px = x + w - pad - pw
    local vx = px - pad - vw
    local mx = vx - pad - pw
    return {
        give  = { x, y, mx - 0.006 - x, h },
        minus = { mx, iy, pw, ih },
        value = { vx, iy, vw, ih },
        plus  = { px, iy, pw, ih },
    }
end

-- the BUFFS entry under the cursor, and which part of a timed card
-- ("give" / "minus" / "value" / "plus"; "btn" for the plain buttons)
local function buff_hit(cursor)
    local hit_e, hit_part = nil, nil
    buffs_layout(function(kind, e, x, y, w, h, timed)
        if kind ~= "entry" or hit_e ~= nil or not C.btn_rect(cursor, x, y, w, h) then return end
        hit_e, hit_part = e, "btn"
        if timed then
            hit_part = "give"
            for name, r in pairs(timed_parts(x, y, w, h)) do
                if name ~= "give" and C.btn_rect(cursor, r[1], r[2], r[3], r[4]) then hit_part = name end
            end
        end
    end)
    return hit_e, hit_part
end

-- seconds a timed card gives
S.buff_secs = S.buff_secs or {}
local BUFF_SECS_MAX = 99999999
local function buff_secs(e)
    local v = S.buff_secs[e.label]
    if v == nil then v = e.secs or 30 end
    return v
end
local function buff_secs_set(e, v)
    v = math.floor(tonumber(v) or 0)
    if v < 1 then v = 1 end
    if v > BUFF_SECS_MAX then v = BUFF_SECS_MAX end
    S.buff_secs[e.label] = v
end

-- - / + step: nothing held 10, Ctrl 100, Shift 1K, Ctrl+Shift 10K (same keys
-- as the INTERACT amounts; no Alt: not in the window key table)
local function buff_step()
    local ctrl  = ga_win_key_down("LCTRL") or ga_win_key_down("RCTRL")
    local shift = ga_win_key_down("LSHIFT") or ga_win_key_down("RSHIFT")
    if ctrl and shift then return 10000 end
    if shift then return 1000 end
    if ctrl then return 100 end
    return 10
end

-- L-click a timed card's name: set its timer(s) to the card's seconds
local function give_timed(e)
    local secs = buff_secs(e)
    local vars = e.all_keys and ALL_KEY_VARS or { e.var }
    local n = 0
    for _, var in ipairs(vars) do
        if ga_exists(var) then ga_set_f(var, secs); n = n + 1 end
    end
    if n == 0 then ga_hud_msg(e.label .. ": not in this game version", 1.5) return end
    ga_hud_msg(e.label .. " " .. secs .. "s", 1.5)
end

-- R-click: take that buff away (timer -> 0) / turn the cheat off
local function remove_buff(e)
    local name = e.label
    if e.toggle then
        if cheat_state(e.toggle) == false then
            ga_hud_msg(e.label .. " is already off", 1.5)
            ga_play_sound("menu_back")
            return
        end
        if e.set then
            e.set(false)                  -- (shows its own message)
        else
            ga_command(e.off)             -- explicit "x off" (or "cheat off")
            ga_hud_msg(e.label .. " off", 1.5)
        end
        poll_cheats(true)
    elseif e.all_keys then
        for _, var in ipairs(ALL_KEY_VARS) do
            if ga_exists(var) then ga_set_f(var, 0.0) end
        end
        ga_hud_msg("All keys removed", 1.5)
    elseif e.var then
        if not ga_exists(e.var) then return end
        ga_set_f(e.var, 0.0)
        ga_hud_msg(name .. " removed", 1.5)
    else
        return                            -- paths / actions: nothing to remove
    end
    ga_play_sound("menu_back")
end

local GUN_UPGRADE_SUFFIXES = {
    "ammo_level", "ammo_regen_level", "damage_level", "speed_level",
    "fire_period_level", "num_level", "radius_level", "freeze_time_level",
}

local function set_var_if_exists(var, value)
    if ga_exists(var) then ga_set_i(var, value) end
end

local function gun_prefix(n) return "xar.player.gun" .. (n or S.sel_weapon) .. "." end

local function set_gun_ammo(n, value)
    set_var_if_exists(gun_prefix(n) .. "ammo", value)
    ga_hud_msg("weapon " .. n .. " ammo -> " .. value, 1.5)
end

local function set_gun_upgrades(n, value)
    for _, suf in ipairs(GUN_UPGRADE_SUFFIXES) do
        set_var_if_exists(gun_prefix(n) .. suf, value)
    end
    ga_hud_msg("weapon " .. n .. (value > 0 and " upgrades -> " or " upgrades removed -> ") .. value, 1.5)
end

local function set_sel_ammo(value) set_gun_ammo(S.sel_weapon, value) end
local function set_sel_upgrades(value) set_gun_upgrades(S.sel_weapon, value) end

local function equip_sel()
    ga_set_i("xar.player.cur_wep", S.sel_weapon)
    C.set_build_mode(false)
    ga_hud_msg("equipped weapon " .. S.sel_weapon, 1.5)
end

local function is_equipped(n) return ga_get_i("xar.player.cur_wep") == n end

local function max_ammo_for_sel()
    if game_wep_modes and game_wep_modes.get_ammo_max then
        local ok, v = pcall(game_wep_modes.get_ammo_max, S.sel_weapon)
        if ok and type(v) == "number" then return v end
    end
    return 999
end

local WEP_ACTION_ROWS = {
    { header = "AMMO", icon = "@sel_ammo", buttons = {
        { label = "Max Ammo",    fn = function() set_sel_ammo(max_ammo_for_sel()) end },
        { label = "Refill 999",  fn = function() set_sel_ammo(999) end },
        { label = "Empty Ammo",  fn = function() set_sel_ammo(0) end },
    }},
    { header = "UPGRADES", icon = "upgrade_station", buttons = {
        { label = "Upgrades 100",    fn = function() set_sel_upgrades(100) end },
        { label = "Upgrades 1000",   fn = function() set_sel_upgrades(1000) end },
        { label = "Upgrades 10000",  fn = function() set_sel_upgrades(10000) end },
        { label = "Remove Upgrades", fn = function() set_sel_upgrades(0) end },
    }},
    { header = "EQUIP", icon = "icon_rocket", buttons = {
        { label = "Equip Selected", fn = equip_sel, active = function() return is_equipped(S.sel_weapon) end },
    }},
}

local WEP_NAMES = { [0] = "Dark Hole", "Plasma", "Cannon", "Laser", "Rocket",
                    "Homing Rocket", "Minigun", "Railgun", "EMP", "Nuke" }
local function wep_name(n)
    if game_wep_modes and game_wep_modes.get_wep_name then
        local ok, nm = pcall(game_wep_modes.get_wep_name, n)
        if ok and type(nm) == "string" and nm ~= "ERROR" then return nm end
    end
    return WEP_NAMES[n] or ("Weapon " .. n)
end

local function gun_i(n, suffix, default)
    local var = "xar.player.gun" .. n .. "." .. suffix
    if ga_exists(var) then return ga_get_i(var) end
    return default
end

-- first upgrade var this gun has (the upgrade buttons set them all to the same value)
local function gun_upgrade_level(n)
    for _, suf in ipairs(GUN_UPGRADE_SUFFIXES) do
        local v = gun_i(n, suf, nil)
        if v ~= nil then return v end
    end
    return 0
end

local function gun_has_upgrades(n)
    for _, suf in ipairs(GUN_UPGRADE_SUFFIXES) do
        if ga_exists(gun_prefix(n) .. suf) then return true end
    end
    return false
end

-- weapon strip: 10 square tiles centred under the tab bar
local WEP_TILE_H, WEP_TILE_GAP, WEP_TILE_TOP = 0.100, 0.014, 0.780
local function wep_tile_rect(n)
    local tw  = WEP_TILE_H / S.aspect
    local gap = WEP_TILE_GAP / S.aspect
    local x   = 0.5 - (10 * tw + 9 * gap) * 0.5 + n * (tw + gap)
    return x, WEP_TILE_TOP - WEP_TILE_H, x + tw, WEP_TILE_TOP
end
local function wep_hovered(cursor)
    for n = 0, 9 do
        local x0, y0, x1, y1 = wep_tile_rect(n)
        if cursor.x >= x0 and cursor.x <= x1 and cursor.y >= y0 and cursor.y <= y1 then return n end
    end
    return -1
end

-- detail panel rows: label on the left, buttons on the right (same look as the ITEMS cards)
local WEP_ROW_Y0, WEP_ROW_PITCH = 0.470, 0.080
local WEP_BTN_X0, WEP_BTN_W, WEP_BTN_H, WEP_BTN_GAP = 0.27, 0.155, 0.035, 0.010
local function wep_buttons_layout(cb_section, cb_button)
    local by = WEP_ROW_Y0
    for _, row in ipairs(WEP_ACTION_ROWS) do
        if cb_section then cb_section(row, by) end
        local bx = WEP_BTN_X0
        for _, b in ipairs(row.buttons) do
            cb_button(b, bx, by, WEP_BTN_W, WEP_BTN_H)
            bx = bx + WEP_BTN_W + WEP_BTN_GAP
        end
        by = by - WEP_ROW_PITCH
    end
end

-------------------------------------------------------------------------------
-- Weapon (fire) modes. Every xar gun has 2..6 modes; a mode must be unlocked
-- ("has", normally via weapon-mod pickups) and two are equipped at a time
-- (lowest-numbered = primary fire, other = secondary). Vars, all declared in
-- xar globals.txt:
--   xar.player.gunN.modeM.has / .equipped        (b)
--   xar.player.gunN.last_mode / .last_last_mode  (i)
--   xar.player.equipped.N.primary / .secondary   (s, "item_gun_N_M" = the item
--                                                 script that fires)
-- Mirrors xar Game/game_wep_modes.lua (give_mode / equip_mode /
-- refresh_equip_strs) with plain ga_get/ga_set calls, because game modules
-- are not reliably visible from the window Lua state.
-------------------------------------------------------------------------------

local WEP_MODE_NAMES = {
    [1] = { "Basic High DPA", "Rapid Fire", "Plasma Shotgun", "Hyper Rapid Fire", "Lightning Rifle", "Flare" },
    [2] = { "Blunderbuss", "Tommy Gun", "Chaining Cannon Ball", "The Sheriff", "The Judge" },
    [3] = { "Ice Laser", "Cold Beam", "Freeze Ray", "Laser Disco" },
    [4] = { "Basic Rocket", "High Velocity Rocket", "Big Radius Rocket", "Kinetic Rocket", "Progressive Rocket" },
    [5] = { "Single Shot", "Cluster Shot" },
    [6] = { "Rapid Fire", "Poison Dart" },
    [7] = { "Classic Railgun", "Rapid Railgun", "Vampire Railgun", "Super Vampire Railgun" },
    [8] = { "EMP", "EMP With Damage" },
    [9] = { "High Damage", "High Velocity and Radius", "Nuclear Pulse Propulsion" },
    [0] = { "Dark Hole Launcher", "Exchange Health for Hole", "Black Hole Drive", "Quasar Drive" },
}

-- new-game state (xar globals.txt): unlocked modes, equipped modes, last_mode, last_last_mode
local WEP_MODE_DEFAULTS = {
    [1] = { has = { 1, 2 }, eq = { 1, 2 }, last = 1, last_last = 2 },
    [2] = { has = { 1, 3 }, eq = { 1, 3 }, last = 1, last_last = 2 },
    [3] = { has = { 1, 4 }, eq = { 1, 4 }, last = 1, last_last = 4 },
    [4] = { has = { 1, 4 }, eq = { 1, 4 }, last = 1, last_last = 4 },
    [5] = { has = { 1, 2 }, eq = { 1, 2 }, last = 1, last_last = 2 },
    [6] = { has = { 1, 2 }, eq = { 1, 2 }, last = 1, last_last = 2 },
    [7] = { has = { 1, 3 }, eq = { 1, 3 }, last = 1, last_last = 2 },
    [8] = { has = { 1, 2 }, eq = { 1, 2 }, last = 1, last_last = 2 },
    [9] = { has = { 1, 2 }, eq = { 1, 2 }, last = 1, last_last = 2 },
    [0] = { has = { 1, 2 }, eq = { 1, 2 }, last = 1, last_last = 2 },
}

local function mode_var(n, m, what) return gun_prefix(n) .. "mode" .. m .. "." .. what end

-- number of modes = how many modeM.has vars the game declares for this gun
local function wep_mode_count(n)
    local m = 0
    while m < 12 and ga_exists(mode_var(n, m + 1, "has")) do m = m + 1 end
    return m
end

local function wep_mode_name(n, m)
    if game_wep_modes and game_wep_modes.get_wep_mode_name then
        local ok, nm = pcall(game_wep_modes.get_wep_mode_name, n, m)
        if ok and type(nm) == "string" and nm ~= "NOT YET DONE!!!" then return nm end
    end
    local t = WEP_MODE_NAMES[n]
    return (t and t[m]) or ("Mode " .. m)
end

local function mode_flag(n, m, what)
    local var = mode_var(n, m, what)
    return ga_exists(var) and ga_get_b(var)
end
local function mode_has(n, m) return mode_flag(n, m, "has") end
local function mode_equipped(n, m) return mode_flag(n, m, "equipped") end

local function set_mode_flag(n, m, what, value)
    local var = mode_var(n, m, what)
    if ga_exists(var) then ga_set_b(var, value) end
end

local function set_gun_s(n, suffix, value)
    local var = "xar.player.equipped." .. n .. "." .. suffix
    if ga_exists(var) then ga_set_s(var, value) end
end

-- equipped modes in mode order: [1] = primary fire, [2] = secondary fire
local function equipped_modes(n)
    local list = {}
    for m = 1, wep_mode_count(n) do
        if mode_equipped(n, m) then list[#list + 1] = m end
    end
    return list
end

-- = game_wep_modes.refresh_equip_strs: the item scripts the fire keys run
local function refresh_equip_strs(n)
    local eq = equipped_modes(n)
    if eq[1] then set_gun_s(n, "primary",   "item_gun_" .. n .. "_" .. eq[1]) end
    if eq[2] then set_gun_s(n, "secondary", "item_gun_" .. n .. "_" .. eq[2]) end
end

-- the mode that stays equipped when another one is equipped
-- (game_wep_modes.equip_mode keeps the last chosen mode, drops the other one)
local function equip_keeps(n)
    local last = gun_i(n, "last_mode", 1)
    if last < 1 or last > wep_mode_count(n) or not mode_equipped(n, last) then
        last = equipped_modes(n)[1] or 1
    end
    return last
end

local function equip_mode(n, m)
    if mode_equipped(n, m) then
        ga_hud_msg(wep_name(n) .. ": " .. wep_mode_name(n, m) .. " is already equipped", 2.0)
        return
    end
    local last = equip_keeps(n)
    for i = 1, wep_mode_count(n) do set_mode_flag(n, i, "equipped", false) end
    set_mode_flag(n, last, "equipped", true)
    set_mode_flag(n, m, "equipped", true)
    refresh_equip_strs(n)
    set_var_if_exists(gun_prefix(n) .. "last_mode", m)
    set_var_if_exists(gun_prefix(n) .. "last_last_mode", last)
    ga_play_sound("menu_select")
    ga_hud_msg(wep_name(n) .. ": equipped " .. wep_mode_name(n, m), 2.0)
end

local function unlock_mode(n, m)
    set_mode_flag(n, m, "has", true)
    ga_play_sound("fanfare")
    ga_hud_msg("New weapon mode: " .. wep_name(n) .. ": " .. wep_mode_name(n, m), 3.0)
end

local function lock_mode(n, m)
    if not mode_has(n, m) then return end
    if mode_equipped(n, m) then
        ga_play_sound("menu_back")
        ga_hud_msg("Can't lock an equipped mode - equip another " .. wep_name(n) .. " mode first", 3.0)
        return
    end
    set_mode_flag(n, m, "has", false)
    ga_play_sound("menu_select")
    ga_hud_msg(wep_name(n) .. ": locked " .. wep_mode_name(n, m), 2.0)
end

-- returns how many modes were newly unlocked
local function unlock_all_modes(n)
    local got = 0
    for m = 1, wep_mode_count(n) do
        if not mode_has(n, m) then
            set_mode_flag(n, m, "has", true)
            got = got + 1
        end
    end
    return got
end

local function reset_modes(n)
    local d = WEP_MODE_DEFAULTS[n]
    if d == nil then return end
    local has, eq = {}, {}
    for _, m in ipairs(d.has) do has[m] = true end
    for _, m in ipairs(d.eq) do eq[m] = true end
    for m = 1, wep_mode_count(n) do
        set_mode_flag(n, m, "has", has[m] == true)
        set_mode_flag(n, m, "equipped", eq[m] == true)
    end
    set_var_if_exists(gun_prefix(n) .. "last_mode", d.last)
    set_var_if_exists(gun_prefix(n) .. "last_last_mode", d.last_last)
    refresh_equip_strs(n)
end

local function modes_unlock_sel()
    local got = unlock_all_modes(S.sel_weapon)
    if got > 0 then ga_play_sound("fanfare") else ga_play_sound("menu_select") end
    ga_hud_msg(wep_name(S.sel_weapon) .. ": all modes unlocked"
        .. (got > 0 and (" (+" .. got .. ")") or " (had them all)"), 2.5)
end

local function modes_unlock_every()
    local got = 0
    for n = 0, 9 do got = got + unlock_all_modes(n) end
    if got > 0 then ga_play_sound("fanfare") else ga_play_sound("menu_select") end
    ga_hud_msg("Every weapon mode unlocked" .. (got > 0 and (" (+" .. got .. ")") or " (had them all)"), 2.5)
end

local function modes_reset_sel()
    reset_modes(S.sel_weapon)
    ga_play_sound("menu_select")
    ga_hud_msg(wep_name(S.sel_weapon) .. ": modes reset to new-game defaults", 2.5)
end

-- MODES panel under the weapon detail panel
local MODES_Y0, MODES_Y1 = 0.084, 0.232
local MODES_X0, MODES_X1 = 0.04, 0.96
local MODE_BTN_W, MODE_BTN_H, MODE_BTN_GAP, MODE_BTN_TOP = 0.112, 0.030, 0.008, 0.226
local MODE_CHIP_H, MODE_CHIP_GAP, MODE_CHIP_TOP, MODE_CHIP_ROW = 0.030, 0.010, 0.186, 0.040
local MODE_BUTTONS = {
    { label = "Unlock All", fn = modes_unlock_sel },
    { label = "Every Gun",  fn = modes_unlock_every },
    { label = "Defaults",   fn = modes_reset_sel },
}

local function modes_buttons_layout(cb)
    local n = #MODE_BUTTONS
    local bx = MODES_X1 - n * MODE_BTN_W - (n - 1) * MODE_BTN_GAP
    for _, b in ipairs(MODE_BUTTONS) do
        cb(b, bx, MODE_BTN_TOP - MODE_BTN_H, MODE_BTN_W, MODE_BTN_H)
        bx = bx + MODE_BTN_W + MODE_BTN_GAP
    end
end

-- chip rects (x, y = bottom left) for the selected gun's modes
local function mode_chips_layout(n, cb)
    local count = wep_mode_count(n)
    if count == 0 then return end
    local cols = math.max(3, math.ceil(count / 2))
    local cw = (MODES_X1 - MODES_X0 - (cols - 1) * MODE_CHIP_GAP) / cols
    for m = 1, count do
        local col, row = (m - 1) % cols, math.floor((m - 1) / cols)
        local x = MODES_X0 + col * (cw + MODE_CHIP_GAP)
        local top = MODE_CHIP_TOP - row * MODE_CHIP_ROW
        cb(m, x, top - MODE_CHIP_H, cw, MODE_CHIP_H)
    end
end

local function mode_chip_hovered(n, cursor)
    local hit = nil
    mode_chips_layout(n, function(m, x, y, w, h)
        if C.btn_rect(cursor, x, y, w, h) then hit = m end
    end)
    return hit
end

-------------------------------------------------------------------------------
-- Telekinesis upgrades (ITEMS tab). In the game each one comes from an
-- "Upgrade Telekinesis" station (xar BasicEnts/Store/bent_upgrade_telekinesis:
-- ga_set_b on its var) and adds +1 block radius / -1 s free cooldown
-- (xar Game/game_telekinesis.lua). xar globals.txt declares the vars as
-- "b game.globals.xar.player.telekinesis.<name>" and xar reads them with that
-- same string, so we do too.
-------------------------------------------------------------------------------

local TELE_UPGRADES = {   -- { api name, xar's display name }, in game_telekinesis order
    { "stone_corral",             "Stone Corral (Richmond, in Midway)" },
    { "huntington",               "Huntington (Midway)" },
    { "starksboro",               "Starksboro (I3)" },
    { "desert_flower_cloud",      "Desert Flower Secret (I3)" },
    { "tangerine",                "Tangerine (I3)" },
    { "super_massive_black_hole", "Super Massive Black Hole (Space)" },
    { "top_of_world",             "Top of the World" },
    { "absolute_infinite",        "Absolute Infinite" },
    { "secret_farmhouse",         "Secret Farmhouse" },
    { "main_branch_lib",          "Main Branch Library (Mylantis)" },
    { "mylantis_great_cavern",    "Mylantis Great Cavern (Mylantis)" },
    { "beta_sponge",              "Beta Menger Sponge (Mylantis)" },
}
-- game_telekinesis get_radius_base / get_free_cooldown_base
local TELE_RADIUS_BASE, TELE_COOLDOWN_BASE = 24, 30

local function tele_var(name) return "game.globals.xar.player.telekinesis." .. name end
local function tele_has(name)
    local var = tele_var(name)
    return ga_exists(var) and ga_get_b(var) == true
end
-- false when this game version doesn't have that upgrade
local function tele_set(name, value)
    local var = tele_var(name)
    if not ga_exists(var) then return false end
    ga_set_b(var, value)
    return true
end
local function tele_count()
    local n = 0
    for _, u in ipairs(TELE_UPGRADES) do
        if tele_has(u[1]) then n = n + 1 end
    end
    return n
end

local function tele_unlock(u)
    if tele_has(u[1]) then
        ga_play_sound("menu_select")
        ga_hud_msg("Telekinesis: " .. u[2] .. " is already unlocked", 2.0)
    elseif tele_set(u[1], true) then
        ga_play_sound("oh_yeah")                  -- (what the upgrade station plays)
        ga_hud_msg("Telekinesis upgrade: " .. u[2], 2.5)
    else
        ga_play_sound("menu_back")
        ga_hud_msg("Telekinesis: " .. u[2] .. " is not in this game version", 2.5)
    end
end

local function tele_lock(u)
    if not tele_has(u[1]) then return end
    tele_set(u[1], false)
    ga_play_sound("menu_select")
    ga_hud_msg("Telekinesis: locked " .. u[2], 2.0)
end

local function tele_unlock_all()
    local got = 0
    for _, u in ipairs(TELE_UPGRADES) do
        if not tele_has(u[1]) and tele_set(u[1], true) then got = got + 1 end
    end
    ga_play_sound((got > 0) and "oh_yeah" or "menu_select")
    ga_hud_msg("All telekinesis upgrades unlocked" .. ((got > 0) and (" (+" .. got .. ")") or " (had them all)"), 2.5)
end

local function tele_lock_all()
    local n = 0
    for _, u in ipairs(TELE_UPGRADES) do
        if tele_has(u[1]) then tele_set(u[1], false); n = n + 1 end
    end
    ga_play_sound("menu_select")
    ga_hud_msg("Telekinesis upgrades locked" .. ((n > 0) and (" (-" .. n .. ")") or " (had none)"), 2.5)
end

-- panel under the ITEMS rows (they end with the XP line at ~0.42)
local TELE_Y0, TELE_Y1 = 0.080, 0.395
local TELE_X0, TELE_X1 = 0.04, 0.96
local TELE_BTN_W, TELE_BTN_H, TELE_BTN_GAP, TELE_BTN_TOP = 0.112, 0.030, 0.008, 0.387
local TELE_CHIP_H, TELE_CHIP_GAP, TELE_CHIP_TOP, TELE_CHIP_ROW = 0.028, 0.010, 0.345, 0.036
local TELE_BUTTONS = {
    { label = "Unlock All", fn = tele_unlock_all },
    { label = "Lock All",   fn = tele_lock_all },
}

local function tele_buttons_layout(cb)
    local n = #TELE_BUTTONS
    local bx = TELE_X1 - n * TELE_BTN_W - (n - 1) * TELE_BTN_GAP
    for _, b in ipairs(TELE_BUTTONS) do
        cb(b, bx, TELE_BTN_TOP - TELE_BTN_H, TELE_BTN_W, TELE_BTN_H)
        bx = bx + TELE_BTN_W + TELE_BTN_GAP
    end
end

-- 2 columns, filled top to bottom (Midway / I3 / Space left, the rest right)
local function tele_chips_layout(cb)
    local rows = math.ceil(#TELE_UPGRADES / 2)
    local cw = (TELE_X1 - TELE_X0 - TELE_CHIP_GAP) / 2
    for i, u in ipairs(TELE_UPGRADES) do
        local col, row = math.floor((i - 1) / rows), (i - 1) % rows
        local x = TELE_X0 + col * (cw + TELE_CHIP_GAP)
        local top = TELE_CHIP_TOP - row * TELE_CHIP_ROW
        cb(u, x, top - TELE_CHIP_H, cw, TELE_CHIP_H)
    end
end

local function tele_chip_hovered(cursor)
    local hit = nil
    tele_chips_layout(function(u, x, y, w, h)
        if C.btn_rect(cursor, x, y, w, h) then hit = u end
    end)
    return hit
end

-- ITEMS / BUFFS / WEAPONS clicks. Returns true when the window was closed.
function C.panels_input(wid)

    if S.cur_tab == C.TAB_ITEMS and ga_win_mouse_pressed(wid, true) then
        local cursor = ga_win_get_cursor_pos(wid)
        local by = 0.78
        for _, section in ipairs(ITEM_BUTTONS) do
            local bx = 0.30
            for _, b in ipairs(section.buttons) do
                local bw = 0.12
                local bh = 0.035
                if C.btn_rect(cursor, bx, by - bh, bw, bh) then
                    if b.delta then
                        C.set_var("di " .. section.var .. " " .. tostring(b.delta))
                    else
                        C.set_var("i " .. section.var .. " " .. tostring(b.value))
                    end
                    ga_play_sound("menu_select")
                end
                bx = bx + bw + 0.01
            end
            by = by - 0.07
        end
        -- telekinesis: Unlock All / Lock All, L-click a locked upgrade = unlock it
        tele_buttons_layout(function(b, bx, by2, bw, bh)
            if C.btn_rect(cursor, bx, by2, bw, bh) then b.fn() end
        end)
        local u = tele_chip_hovered(cursor)
        if u then tele_unlock(u) end
    end
    -- R-click a telekinesis upgrade = lock it again
    if S.cur_tab == C.TAB_ITEMS and ga_win_mouse_pressed(wid, false) then
        local u = tele_chip_hovered(ga_win_get_cursor_pos(wid))
        if u then tele_lock(u) end
    end

    -- BUFFS: L-click = give / toggle, R-click = remove that buff / turn it off
    if S.cur_tab == C.TAB_BUFFS and ga_win_mouse_pressed(wid, true) then
        local e, part = buff_hit(ga_win_get_cursor_pos(wid))
        if e ~= nil and part ~= "value" then       -- (the seconds: num_field opens it)
            if e.path then
                C.pick_and_build("path", e.path, e.label)   -- pops the window
                return true
            elseif e.action then
                C.pick_and_build("action", e.action, e.label)
                return true
            elseif e.toggle then
                run_cheat_toggle(e)
            elseif part == "minus" then
                buff_secs_set(e, buff_secs(e) - buff_step())
            elseif part == "plus" then
                buff_secs_set(e, buff_secs(e) + buff_step())
            elseif e.secs then
                give_timed(e)
            end
            ga_play_sound("menu_select")
        end
    end
    if S.cur_tab == C.TAB_BUFFS and ga_win_mouse_pressed(wid, false) then
        local e, part = buff_hit(ga_win_get_cursor_pos(wid))
        if e ~= nil and (part == "give" or part == "btn") then remove_buff(e) end
    end

    -- mouse wheel cycles the selected weapon (down = next, like the hotbar)
    if S.cur_tab == C.TAB_WEAPONS then
        local step = 0
        if ga_win_mouse_wheel_down(wid) then step = step + 1 end
        if ga_win_mouse_wheel_up(wid) then step = step - 1 end
        if step ~= 0 then
            C.num_edit_commit()   -- an open ammo/upgrade field belongs to the old weapon
            S.sel_weapon = (S.sel_weapon + step) % 10
            ga_play_sound("menu_move")
        end
    end

    if S.cur_tab == C.TAB_WEAPONS and ga_win_mouse_pressed(wid, true) then
        local cursor = ga_win_get_cursor_pos(wid)
        local n = wep_hovered(cursor)
        if n >= 0 then
            S.sel_weapon = n
            ga_play_sound("menu_select")
        end
        wep_buttons_layout(nil, function(b, bx, by, bw, bh)
            if C.btn_rect(cursor, bx, by - bh, bw, bh) then
                b.fn()
                ga_play_sound("menu_select")
            end
        end)
        -- MODES panel (these play their own sounds)
        modes_buttons_layout(function(b, bx, by, bw, bh)
            if C.btn_rect(cursor, bx, by, bw, bh) then b.fn() end
        end)
        local m = mode_chip_hovered(S.sel_weapon, cursor)
        if m then
            if mode_has(S.sel_weapon, m) then equip_mode(S.sel_weapon, m)
            else unlock_mode(S.sel_weapon, m) end
        end
    end

    -- R-click a mode = lock it again
    if S.cur_tab == C.TAB_WEAPONS and ga_win_mouse_pressed(wid, false) then
        local m = mode_chip_hovered(S.sel_weapon, ga_win_get_cursor_pos(wid))
        if m then lock_mode(S.sel_weapon, m) end
    end

end

local function panel(wid, x0, y0, x1, y1)
    ga_win_quad_color(wid, x0 - 0.003, y0 - 0.003, x1 + 0.003, y1 + 0.003, std.vec(0.15, 0.15, 0.22))
    ga_win_quad_color(wid, x0, y0, x1, y1, std.vec(0.08, 0.08, 0.12))
end

local function frame(wid, x0, y0, x1, y1, t, c)
    ga_win_quad_color(wid, x0, y1 - t, x1, y1, c)
    ga_win_quad_color(wid, x0, y0, x1, y0 + t, c)
    ga_win_quad_color(wid, x0, y0, x0 + t / S.aspect, y1, c)
    ga_win_quad_color(wid, x1 - t / S.aspect, y0, x1, y1, c)
end

-- WEAPONS-tab button; (bx, by) = top left
local function draw_wep_btn(wid, cursor, bx, by, bw, bh, label, active)
    local hovering = C.btn_rect(cursor, bx, by - bh, bw, bh)
    local col = active and std.vec(0.50, 0.45, 0.18)
             or (hovering and std.vec(0.45, 0.35, 0.20) or std.vec(0.28, 0.22, 0.13))
    local padding = C.default_padding
    ga_win_quad_color(wid, bx - C.fix_padding(padding), by - bh - padding, bx + bw + C.fix_padding(padding), by + padding, std.vec(0.5, 0.4, 0.2))
    ga_win_quad_color(wid, bx, by - bh, bx + bw, by, col)
    ga_win_set_char_size(wid, 0.009, 0.018)
    ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
    ga_win_txt(wid, bx + 0.006, by - bh * 0.5 - 0.008, label)
    ga_win_set_front_color_default(wid)
end

-- a fire mode / telekinesis upgrade chip: name on the left (cut to fit),
-- optional tag (PRIMARY, LOCKED, ...) on the right
local function draw_chip(wid, x, y, w, h, name, txt, border, bg, tag, tagcol)
    local pad = C.default_padding
    ga_win_quad_color(wid, x - C.fix_padding(pad), y - pad, x + w + C.fix_padding(pad), y + h + pad, border)
    ga_win_quad_color(wid, x, y, x + w, y + h, bg)
    local tag_w = 0
    if tag then
        tag_w = #tag * 0.0075
        ga_win_set_char_size(wid, 0.0075, 0.015)
        ga_win_set_front_color(wid, tagcol)
        ga_win_txt(wid, x + w - 0.008 - tag_w, y + h * 0.5 - 0.007, tag)
    end
    local cw = 0.0085
    ga_win_set_char_size(wid, cw, 0.017)
    ga_win_set_front_color(wid, txt)
    ga_win_txt(wid, x + 0.008, y + h * 0.5 - 0.008, C.fit(name, math.floor((w - 0.024 - tag_w) / cw)))
    ga_win_set_front_color_default(wid)
end

local function render_modes_panel(wid, cursor)
    local n = S.sel_weapon
    local count = wep_mode_count(n)
    panel(wid, 0.02, MODES_Y0, 0.98, MODES_Y1)

    -- header: icon, title, "x / y unlocked", buttons on the right
    local mid = MODE_BTN_TOP - MODE_BTN_H * 0.5
    local hx = MODES_X0 + 0.005
    local hw = C.draw_icon(wid, hx, mid - 0.015, 0.030, "weapon_mode", true)
    if hw > 0 then hx = hx + hw + 0.010 end
    local title = "FIRE MODES"
    ga_win_set_char_size(wid, 0.011, 0.022)
    ga_win_set_front_color(wid, std.vec(1.0, 0.7, 0.3))
    ga_win_txt(wid, hx, mid - 0.009, title)
    local owned = 0
    for m = 1, count do if mode_has(n, m) then owned = owned + 1 end end
    ga_win_set_char_size(wid, 0.009, 0.018)
    ga_win_set_front_color(wid, std.vec(0.55, 0.80, 0.95))
    ga_win_txt(wid, hx + #title * 0.011 + 0.015, mid - 0.008, owned .. " / " .. count .. " unlocked")
    ga_win_set_front_color_default(wid)

    modes_buttons_layout(function(b, bx, by, bw, bh)
        draw_wep_btn(wid, cursor, bx, by + bh, bw, bh, b.label, false)
    end)

    if count == 0 then
        ga_win_set_char_size(wid, 0.009, 0.018)
        ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
        ga_win_txt(wid, MODES_X0, MODE_CHIP_TOP - 0.025, "This weapon has no fire modes.")
        ga_win_set_front_color_default(wid)
        return
    end

    -- one chip per mode: locked = dark + LOCKED, unlocked = brown, equipped = green
    local eq = equipped_modes(n)
    local hov_m = nil
    mode_chips_layout(n, function(m, x, y, w, h)
        local has, equipped = mode_has(n, m), mode_equipped(n, m)
        local hovering = C.btn_rect(cursor, x, y, w, h)
        if hovering then hov_m = m end
        local border, bg, txt, tag, tagcol
        if equipped then
            border = std.vec(0.30, 0.85, 0.40)
            bg     = hovering and std.vec(0.14, 0.38, 0.18) or std.vec(0.10, 0.30, 0.14)
            txt    = std.vec(0.75, 1.0, 0.75)
            tag, tagcol = (eq[1] == m) and "PRIMARY" or "SECONDARY", std.vec(0.45, 1.0, 0.55)
        elseif has then
            border = std.vec(0.5, 0.4, 0.2)
            bg     = hovering and std.vec(0.45, 0.35, 0.20) or std.vec(0.28, 0.22, 0.13)
            txt    = std.vec(1.0, 1.0, 1.0)
        else
            border = hovering and std.vec(1.0, 0.9, 0.3) or std.vec(0.25, 0.25, 0.30)
            bg     = hovering and std.vec(0.20, 0.18, 0.12) or std.vec(0.10, 0.10, 0.13)
            txt    = std.vec(0.50, 0.50, 0.55)
            tag, tagcol = "LOCKED", std.vec(0.80, 0.38, 0.32)
        end
        draw_chip(wid, x, y, w, h, wep_mode_name(n, m), txt, border, bg, tag, tagcol)
    end)
    -- (what clicking a mode does: see the ? help)
end

-- ITEMS tab: TELEKINESIS UPGRADES panel
local function render_tele_panel(wid, cursor)
    panel(wid, 0.02, TELE_Y0, 0.98, TELE_Y1)

    -- header: icon, title, "x / 12 unlocked", buttons on the right
    local mid = TELE_BTN_TOP - TELE_BTN_H * 0.5
    local hx = TELE_X0 + 0.005
    local hw = C.draw_icon(wid, hx, mid - 0.015, 0.030, "upgrade_telekinesis", true)
    if hw > 0 then hx = hx + hw + 0.010 end
    local title = "TELEKINESIS UPGRADES"
    ga_win_set_char_size(wid, 0.011, 0.022)
    ga_win_set_front_color(wid, std.vec(1.0, 0.7, 0.3))
    ga_win_txt(wid, hx, mid - 0.009, title)
    local n = tele_count()
    ga_win_set_char_size(wid, 0.009, 0.018)
    ga_win_set_front_color(wid, std.vec(0.55, 0.80, 0.95))
    ga_win_txt(wid, hx + #title * 0.011 + 0.015, mid - 0.008, n .. " / " .. #TELE_UPGRADES .. " unlocked")
    ga_win_set_front_color_default(wid)

    tele_buttons_layout(function(b, bx, by, bw, bh)
        draw_wep_btn(wid, cursor, bx, by + bh, bw, bh, b.label, false)
    end)

    -- one chip per upgrade: unlocked = green, locked = dark + LOCKED
    tele_chips_layout(function(u, x, y, w, h)
        local hovering = C.btn_rect(cursor, x, y, w, h)
        if tele_has(u[1]) then
            draw_chip(wid, x, y, w, h, u[2], std.vec(0.75, 1.0, 0.75), std.vec(0.30, 0.85, 0.40),
                hovering and std.vec(0.14, 0.38, 0.18) or std.vec(0.10, 0.30, 0.14),
                "UNLOCKED", std.vec(0.45, 1.0, 0.55))
        else
            draw_chip(wid, x, y, w, h, u[2], std.vec(0.50, 0.50, 0.55),
                hovering and std.vec(1.0, 0.9, 0.3) or std.vec(0.25, 0.25, 0.30),
                hovering and std.vec(0.20, 0.18, 0.12) or std.vec(0.10, 0.10, 0.13),
                "LOCKED", std.vec(0.80, 0.38, 0.32))
        end
    end)

    -- what they add up to (game_telekinesis get_radius / get_free_cooldown)
    ga_win_set_char_size(wid, 0.009, 0.018)
    ga_win_set_front_color(wid, std.vec(0.55, 0.80, 0.95))
    ga_win_txt(wid, TELE_X0 + 0.005, TELE_Y0 + 0.016,
        "Radius " .. TELE_RADIUS_BASE .. " + " .. n .. " = " .. (TELE_RADIUS_BASE + n) .. " blocks"
        .. "      Free telekinesis cooldown " .. TELE_COOLDOWN_BASE .. " - " .. n .. " = "
        .. (TELE_COOLDOWN_BASE - n) .. " s")
    ga_win_set_front_color_default(wid)
end

function C.render_weapons_tab(wid)
    local cursor = ga_win_get_cursor_pos(wid)

    ga_win_set_char_size(wid, 0.012, 0.024)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt_center(wid, 0.810, "WEAPON LOADOUT")
    ga_win_set_front_color_default(wid)

    -- weapon strip ---------------------------------------------------------
    local sx0 = wep_tile_rect(0) - 0.02
    local _, _, sx1 = wep_tile_rect(9)
    sx1 = sx1 + 0.02
    panel(wid, sx0, WEP_TILE_TOP - WEP_TILE_H - 0.048, sx1, WEP_TILE_TOP + 0.012)

    local hov = wep_hovered(cursor)
    for n = 0, 9 do
        local x0, y0, x1, y1 = wep_tile_rect(n)
        local ammo = gun_i(n, "ammo", 0)
        local tex = "ammo_gun" .. n
        if ammo <= 0 and C.ntex(tex .. "_grey") then tex = tex .. "_grey" end
        ga_win_quad_color(wid, x0 - 0.002 / S.aspect, y0 - 0.002, x1 + 0.002 / S.aspect, y1 + 0.002, std.vec(0, 0, 0))
        C.draw_icon(wid, x0, y0, y1 - y0, tex, false)
        if n == S.sel_weapon then
            frame(wid, x0, y0, x1, y1, 0.005, std.vec(1.0, 0.9, 0.2))
        elseif n == hov then
            frame(wid, x0, y0, x1, y1, 0.004, std.vec(1.0, 1.0, 1.0))
        end
        if is_equipped(n) then
            ga_win_quad_color(wid, x0, y0 - 0.011, x1, y0 - 0.006, std.vec(0.30, 0.90, 0.40))
        end
        local acol = ammo > 0 and std.vec(0.75, 0.75, 0.80) or std.vec(0.75, 0.35, 0.30)
        if ga_exists(gun_prefix(n) .. "ammo") then
            -- click the number to type this gun's ammo
            local gn = n
            num_field(wid, "ammo:" .. n, (x0 + x1) * 0.5, y0 - 0.034, 0.0075, 0.015, ammo,
                function(v) set_gun_ammo(gn, v) end,
                { center = true, max_w = x1 - x0, col = acol })
        else
            local s  = tostring(ammo)
            local cw = math.min(0.0075, (x1 - x0) / math.max(1, #s))
            ga_win_set_char_size(wid, cw, cw * 2)
            ga_win_set_front_color(wid, acol)
            ga_win_txt(wid, (x0 + x1) * 0.5 - cw * #s * 0.5, y0 - 0.034, s)
            ga_win_set_front_color_default(wid)
        end
    end

    -- selected weapon panel -------------------------------------------------
    panel(wid, 0.02, WEP_ROW_Y0 - 2 * WEP_ROW_PITCH - 0.064, 0.98, 0.615)

    local ih = 0.080
    local iw = C.draw_icon(wid, 0.04, 0.520, ih, "ammo_gun" .. S.sel_weapon, true)
    local tx = 0.04 + iw + 0.020
    ga_win_set_char_size(wid, 0.016, 0.032)
    ga_win_set_front_color(wid, std.vec(1.0, 0.9, 0.45))
    ga_win_txt(wid, tx, 0.565, string.upper(wep_name(S.sel_weapon)))
    -- "Slot N    Ammo <n>    Upgrade level <n>"; both numbers are click-to-type
    local sw = S.sel_weapon
    local ix, icw, ich = tx, 0.009, 0.018
    local function info_txt(s)
        ga_win_set_char_size(wid, icw, ich)
        ga_win_set_front_color(wid, std.vec(0.55, 0.80, 0.95))
        ga_win_txt(wid, ix, 0.528, s)
        ga_win_set_front_color_default(wid)
        ix = ix + #s * icw
    end
    info_txt("Slot " .. sw .. "    Ammo ")
    if ga_exists(gun_prefix(sw) .. "ammo") then
        ix = ix + num_field(wid, "sel_ammo:" .. sw, ix, 0.528, icw, ich, gun_i(sw, "ammo", 0),
            function(v) set_gun_ammo(sw, v) end, { col = std.vec(1.0, 1.0, 1.0) })
    else
        info_txt("-")
    end
    info_txt("    Upgrade level ")
    if gun_has_upgrades(sw) then
        num_field(wid, "sel_upg:" .. sw, ix, 0.528, icw, ich, gun_upgrade_level(sw),
            function(v) set_gun_upgrades(sw, v) end, { col = std.vec(1.0, 1.0, 1.0) })
    else
        info_txt(tostring(gun_upgrade_level(sw)))
    end

    if is_equipped(S.sel_weapon) then
        local bx0, bx1, by0, by1 = 0.83, 0.96, 0.548, 0.585
        ga_win_quad_color(wid, bx0 - 0.002 / S.aspect, by0 - 0.002, bx1 + 0.002 / S.aspect, by1 + 0.002, std.vec(0.30, 0.85, 0.40))
        ga_win_quad_color(wid, bx0, by0, bx1, by1, std.vec(0.10, 0.30, 0.14))
        ga_win_set_char_size(wid, 0.009, 0.018)
        ga_win_set_front_color(wid, std.vec(0.75, 1.0, 0.75))
        ga_win_txt(wid, (bx0 + bx1) * 0.5 - 0.009 * 4, (by0 + by1) * 0.5 - 0.008, "EQUIPPED")
        ga_win_set_front_color_default(wid)
    end

    ga_win_quad_color(wid, 0.04, 0.503, 0.96, 0.505, std.vec(0.20, 0.20, 0.30))

    wep_buttons_layout(
        function(row, by)
            local mid = by - WEP_BTN_H * 0.5
            ga_win_quad_color(wid, 0.03, by - 0.044, 0.97, by + 0.009, std.vec(0.12, 0.12, 0.17))
            local icon = row.icon
            if icon == "@sel_ammo" then icon = "ammo_gun" .. S.sel_weapon end
            local hx = 0.045
            local hw = C.draw_icon(wid, hx, mid - 0.016, 0.032, icon, true)
            if hw > 0 then hx = hx + hw + 0.010 end
            ga_win_set_char_size(wid, 0.011, 0.022)
            ga_win_set_front_color(wid, std.vec(1.0, 0.7, 0.3))
            ga_win_txt(wid, hx, mid - 0.009, row.header)
            ga_win_set_front_color_default(wid)
        end,
        function(b, bx, by, bw, bh)
            draw_wep_btn(wid, cursor, bx, by, bw, bh, b.label, b.active and b.active())
        end)

    render_modes_panel(wid, cursor)

    if hov >= 0 then
        local shown = wep_name(hov)
        ga_win_set_char_size(wid, 0.0092, 0.020)
        local tw = 0.0092 * #shown + 0.010
        local ttx, tty = cursor.x + 0.015, cursor.y + 0.015
        if ttx + tw > 0.98 then ttx = 0.98 - tw end
        ga_win_quad_color(wid, ttx - 0.005, tty - 0.005, ttx + tw + 0.005, tty + 0.032, std.vec(0.12, 0.12, 0.18))
        ga_win_quad_color(wid, ttx - 0.003, tty - 0.003, ttx + tw + 0.003, tty + 0.030, std.vec(0.02, 0.02, 0.02))
        ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
        ga_win_txt(wid, ttx + 0.003, tty + 0.005, shown)
        ga_win_set_front_color_default(wid)
    end
end

function C.render_items_tab(wid)
    ga_win_set_char_size(wid, 0.012, 0.024)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt_center(wid, 0.810, "RESOURCE MANAGEMENT")
    ga_win_set_front_color_default(wid)

    local cursor = ga_win_get_cursor_pos(wid)
    local by = 0.78

    for _, section in ipairs(ITEM_BUTTONS) do
        -- row card; the label + icon are centred on the button row
        local mid = by - 0.0175
        ga_win_quad_color(wid, 0.02, by - 0.044, 0.98, by + 0.009, std.vec(0.07, 0.07, 0.11))
        local hx = 0.03
        local hw = C.draw_icon(wid, hx, mid - 0.018, 0.036, section.icon, true)
        if hw > 0 then hx = hx + hw + 0.010 end
        ga_win_set_char_size(wid, 0.011, 0.022)
        ga_win_set_front_color(wid, std.vec(1.0, 0.9, 0.3))
        local lbl = section.section .. ": "
        ga_win_txt(wid, hx, mid - 0.009, lbl)
        ga_win_set_front_color_default(wid)
        -- the amount: click it to type an exact value
        local var, name = section.var, section.section
        local vx = hx + #lbl * 0.011
        num_field(wid, "item:" .. var, vx, mid - 0.009, 0.011, 0.022, ga_get_i(var),
            function(v)
                ga_set_i(var, v)
                ga_hud_msg(name .. " = " .. v, 1.2)
            end,
            { max_w = 0.29 - vx, col = std.vec(1.0, 0.9, 0.3) })

        local bx = 0.30
        ga_win_set_char_size(wid, 0.009, 0.018)
        for _, b in ipairs(section.buttons) do
            local bw = 0.12
            local bh = 0.035
            local hovering = C.btn_rect(cursor, bx, by - bh, bw, bh)
            local col = hovering and std.vec(0.4, 0.6, 0.8) or std.vec(0.2, 0.3, 0.4)
            ga_win_quad_color(wid, bx, by - bh, bx + bw, by, col)
            local padding = C.default_padding
            ga_win_quad_color(wid, bx - C.fix_padding(padding), by - bh - padding, bx + bw + C.fix_padding(padding), by + padding, std.vec(0.35, 0.35, 0.5))
            ga_win_quad_color(wid, bx, by - bh, bx + bw, by, col)
            ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
            ga_win_txt(wid, bx + 0.005, by - bh + 0.008, b.label)
            ga_win_set_front_color_default(wid)
            bx = bx + bw + 0.01
        end
        by = by - 0.07
    end

    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(0.6, 0.8, 1.0))
    local xp_level = ga_get_i("xar.experience.level")
    local xp_tnl = ga_get_i("xar.experience.to_next_level")
    ga_win_txt(wid, 0.03, by - 0.012, "XP Level: " .. tostring(xp_level) .. "   To Next: " .. tostring(xp_tnl))
    ga_win_set_front_color_default(wid)

    render_tele_panel(wid, cursor)
end

function C.render_buffs_tab(wid)
    ga_win_set_char_size(wid, 0.012, 0.024)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt_center(wid, 0.810, "BUFFS & KEYS")
    ga_win_set_front_color_default(wid)

    local cursor = ga_win_get_cursor_pos(wid)
    poll_cheats(false)
    local step = buff_step()

    local by = buffs_layout(function(kind, e, x, y, w, h, timed)
        if kind == "header" then
            local section = e
            local hx = x
            local hw = section.icon and C.draw_icon(wid, hx, y - 0.005, 0.030, section.icon, true) or 0
            if hw > 0 then hx = hx + hw + 0.008 end
            ga_win_set_char_size(wid, 0.011, 0.022)
            ga_win_set_front_color(wid, std.vec(1.0, 0.7, 0.3))
            ga_win_txt(wid, hx, y, section.section)
            if section.timed then            -- current - / + step (changes with Ctrl / Shift)
                local s = "- / + " .. C.fmt_int(step) .. "s"
                ga_win_set_char_size(wid, 0.008, 0.016)
                ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
                ga_win_txt(wid, hx + #section.section * 0.011 + 0.020, y + 0.002, s)
            end
            ga_win_set_front_color_default(wid)
            return
        end

        local parts = timed and timed_parts(x, y, w, h) or nil
        local g = parts and parts.give or { x, y, w, h }
        local hovering = C.btn_rect(cursor, g[1], g[2], g[3], g[4])
        local col = hovering and std.vec(0.5, 0.4, 0.6) or std.vec(0.25, 0.20, 0.30)
        local border = std.vec(0.40, 0.30, 0.50)
        local on = nil
        if e.toggle then
            on = cheat_state(e.toggle)
            if on == true then               -- same green as an equipped fire mode
                border = std.vec(0.30, 0.85, 0.40)
                col = hovering and std.vec(0.14, 0.38, 0.18) or std.vec(0.10, 0.30, 0.14)
            end
        end
        local padding = C.default_padding
        ga_win_quad_color(wid, x - C.fix_padding(padding), y - padding, x + w + C.fix_padding(padding), y + h + padding, border)
        ga_win_quad_color(wid, x, y, x + w, y + h, timed and std.vec(0.25, 0.20, 0.30) or col)
        if timed and hovering then ga_win_quad_color(wid, g[1], g[2], g[1] + g[3], g[2] + g[4], col) end

        local lx = x + 0.004
        local icon = e.icon
        if e.icon_bent then
            local bt = C.valid_tex(C.bent_tex(e.icon_bent))
            if bt ~= "" then icon = bt end
        end
        local iw = icon and C.draw_icon(wid, lx, y + 0.004, h - 0.008, icon, false) or 0
        if iw > 0 then lx = lx + iw + 0.005 end
        ga_win_set_char_size(wid, 0.008, 0.016)
        ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
        local maxc = math.max(4, math.floor((g[1] + g[3] - 0.004 - lx) / 0.008))
        ga_win_txt(wid, lx, y + h * 0.5 - 0.008, C.fit(e.label, maxc))
        if e.toggle then                     -- ON / OFF / ? tag on the right
            local tag = (on == true) and "ON" or ((on == false) and "OFF" or "?")
            local tcol = (on == true) and std.vec(0.45, 1.0, 0.55)
                      or ((on == false) and std.vec(0.80, 0.38, 0.32) or std.vec(0.6, 0.6, 0.6))
            ga_win_set_front_color(wid, tcol)
            ga_win_txt(wid, x + w - 0.006 - #tag * 0.008, y + h * 0.5 - 0.008, tag)
        end
        ga_win_set_front_color_default(wid)

        if timed then                        -- - [seconds] s +
            local m, v, pl = parts.minus, parts.value, parts.plus
            C.small_btn(wid, cursor, m[1], m[2], m[3], m[4], "-", false)
            C.small_btn(wid, cursor, pl[1], pl[2], pl[3], pl[4], "+", false)
            ga_win_quad_color(wid, v[1], v[2], v[1] + v[3], v[2] + v[4], std.vec(0.03, 0.03, 0.06))
            num_field(wid, "buff:" .. e.label, v[1] + 0.005, v[2] + v[4] * 0.5 - 0.007, 0.008, 0.016,
                buff_secs(e), function(n) buff_secs_set(e, n) end,
                { max_w = v[3] - 0.022, min_w = v[3] - 0.022, col = std.vec(1.0, 0.9, 0.3) })
            ga_win_set_char_size(wid, 0.008, 0.016)
            ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
            ga_win_txt(wid, v[1] + v[3] - 0.012, v[2] + v[4] * 0.5 - 0.007, "s")
            ga_win_set_front_color_default(wid)
        end
    end)

    by = by - 0.03
    ga_win_set_char_size(wid, 0.009, 0.018)
    ga_win_set_front_color(wid, std.vec(0.5, 0.8, 0.5))
    local timer_y = by
    local function show_timer(label, var)
        local val = ga_get_f(var)
        if val > 0 then
            ga_win_txt(wid, 0.03, timer_y, label .. ": " .. string.format("%.1f", val) .. "s remaining")
            timer_y = timer_y - 0.025
        end
    end
    show_timer("5x Damage",      "xar.damage_5x_stacking_time")
    show_timer("Invulnerability", "xar.invun_stacking_time")
    show_timer("5x XP",          "xar.xp_5x_stacking_time")
    show_timer("Yellow Key",     "xar.key_time.yellow")
    show_timer("Blue Key",       "xar.key_time.blue")
    show_timer("Green Key",      "xar.key_time.green")
    show_timer("Universe Key",   "xar.key_time.universe")

    -- "CHEATS: ON   GOD MODE: ON   NOCLIP: OFF   SHRINKANY: ON   ICARUS: OFF"
    timer_y = timer_y - 0.01
    local sx = 0.03
    for _, s in ipairs({ { "CHEATS", "cheats" }, { "GOD MODE", "god" }, { "NOCLIP", "noclip" },
                         { "SHRINKANY", "shrinkany" }, { "ICARUS", "icarus" } }) do
        local on = cheat_state(s[2])
        local txt = s[1] .. ": " .. ((on == true) and "ON" or ((on == false) and "OFF" or "?"))
        ga_win_set_front_color(wid, (on == true) and std.vec(0.4, 1.0, 0.4) or std.vec(0.6, 0.6, 0.6))
        ga_win_txt(wid, sx, timer_y, txt)
        sx = sx + (#txt + 3) * 0.009
    end
    ga_win_set_front_color_default(wid)
end

-- the window calls these at the start of every frame / when it closes
function C.num_frame_begin()
    num_targets = {}             -- num_field() re-registers what is on screen
    num_blink = num_blink + 1
end

function C.num_reset()
    num_edit = nil
    num_targets = {}
    num_last_click = nil
end

-- not a real window: only here so the window Lua state loads it
function p.__start(wid) end
function p.__end(wid) end
function p.__on_start(wid) end
function p.__on_end(wid) end
function p.__render(wid) end
function p.__process_input(wid) end
