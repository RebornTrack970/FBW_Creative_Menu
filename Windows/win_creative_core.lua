-- Creative menu: shared constants, state defaults and small helpers (hotbar
-- data, build mode binds, buttons). Split out of win_creative.lua, which hit
-- Lua's 200-locals limit.
--
-- How the win_creative*.lua files fit together: the engine runs every file in
-- Windows/ in ONE Lua state as `<file> = {}; local p = <file>; <code>`, in an
-- order we don't control. So everything shared lives in the global table
-- creative_ui (C) and mutable state in creative_ui.state (S); every file grabs
-- them with `x = x or {}` at the top and only looks other files' things up
-- when its functions RUN, never while loading.
creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

S.aspect = 1
C.std_aspect = 16/9

-- important: width of ga_win_txt = len_txt*char_width

C.SEL_VAR  = "temp.creative.selected_block"
C.MODE_VAR = "temp.creative.build_mode"

C.TAB_BLOCKS   = 1
C.TAB_WEAPONS  = 2
C.TAB_ITEMS    = 3
C.TAB_BUFFS    = 4
C.TAB_ENTITIES = 5
C.TAB_INTERACT = 6
C.TAB_TELEPORT = 7
C.TAB_DECOR    = 8
C.TAB_COUNT    = 8

C.FAV_VAR   = "temp.creative.favorites"
C.REC_VAR   = "temp.creative.recents"
C.WP_VAR    = "temp.creative.wp_search"
C.BR_SHAPE  = "temp.creative.brush_shape"
C.BR_SIZE   = "temp.creative.brush_size"
C.E_COUNT, C.E_DIST, C.E_FREEZE, C.E_TTL =
    "temp.creative.ent_count", "temp.creative.ent_dist", "temp.creative.ent_freeze",
    "temp.creative.ent_ttl"
-- one placement distance for everything that isn't a block (mouse wheel changes it in-game)
C.D_SIZE, C.D_DIST, C.D_SNAP =
    "temp.creative.decor_size", C.E_DIST, "temp.creative.decor_snap"
C.DIST_MAX = 60

-- hotbar, shared with Game/game_creative.lua: hb1..hb9 = "kind|raw" or ""
C.SLOT_VAR  = "temp.creative.hb_slot"
C.HB_PREFIX = "temp.creative.hb"
C.HB_COUNT  = 9
C.ALT_VAR   = "temp.creative.alt"   -- Alt held (bound in build mode)
C.AREA_VAR  = "temp.creative.area"  -- area-fill size text, set by game_creative

C.X0, C.Y0     = 0.025, 0.78
C.GRID_W     = 0.95
C.GRID_H     = 0.58
C.TILE_Y     = 0.082
C.GAPX, C.GAPY = 0.004, 0.006
S.COLS, S.ROWS = 16, 8
S.CW, S.CH     = C.TILE_Y, C.TILE_Y + C.GAPY
S.PER_PAGE   = S.COLS * S.ROWS

-- makes the text size look the same as std_aspect for all aspect ratios
function C.fix_charw(charw)
    return charw/S.aspect*C.std_aspect
end
function C.fix_padding(padding)
    return padding/S.aspect
end

function C.compute_grid()
    local tile_w = C.TILE_Y / S.aspect
    S.CW = tile_w + C.GAPX
    S.CH = C.TILE_Y + C.GAPY
    S.COLS = math.max(1, math.floor((C.GRID_W + C.GAPX) / S.CW))
    S.ROWS = math.max(1, math.floor((C.GRID_H + C.GAPY) / S.CH))
    S.PER_PAGE = S.COLS * S.ROWS
end

S.cur_tab      = C.TAB_BLOCKS
S.items        = {}
S.page         = 0
S.sel_weapon   = 0
S.view_mode    = "ALL"
S.sort_mode    = "NAME"
S.last_tab     = -1
S.last_search  = nil
S.inited       = false

-- Tabs whose grid the SEARCH box filters. The engine's text input widget
-- can't be hidden or removed once created (it is drawn after __render, so it
-- can't be covered either, and it always draws a cursor), so the window only
-- creates it on these tabs and reopens itself when you switch between a tab
-- with search and one without.
C.SEARCH_TABS = { [C.TAB_BLOCKS] = true, [C.TAB_ENTITIES] = true, [C.TAB_INTERACT] = true,
                      [C.TAB_TELEPORT] = true, [C.TAB_DECOR] = true }
S.has_search  = false   -- this window instance created the search box
S.search_text = ""      -- kept while the menu is closed / reopened
S.tab_pages   = {}      -- grid page per tab, kept while the menu is closed
S.use_3d_mesh  = nil
S.ctrl_down    = false   -- Ctrl held (set every frame in __process_input)

function C.fit(label, n)
    if #label > n then return string.sub(label, 1, n - 1) .. "." end
    return label
end

function C.set_var(cmd_str)
    local a = {}
    for w in string.gmatch(cmd_str or "", "%S+") do a[#a + 1] = w end
    local t, var, val = a[1], a[2], a[3]
    if t == nil or var == nil then return end
    if     t == "di" then ga_set_i_by_delta(var, tonumber(val) or 0)
    elseif t == "i"  then ga_set_i(var, tonumber(val) or 0)
    elseif t == "f"  then ga_set_f(var, tonumber(val) or 0)
    elseif t == "fi" then ga_set_f_by_delta(var, tonumber(val) or 0)
    elseif t == "b"  then ga_set_b(var, val == "true")
    elseif t == "s"  then ga_set_s(var, val or "")
    end
    ga_hud_msg("set " .. var, 1.0)
end

function C.btn_rect(cursor, x, y, w, h)
    return cursor.x >= x and cursor.x <= x + w and cursor.y >= y and cursor.y <= y + h
end
function C.btn_rect2(cursor, x, y, w, h)
    if C.btn_rect(cursor, x, y, w, h) then
        ga_play_sound("menu_select")
        return true
    end
    return false
end

C.default_padding = 0.0025
function C.small_btn(wid, cursor, x, y, w, h, label, active)
    local hov = C.btn_rect(cursor, x, y, w, h)
    local col = active and std.vec(0.50, 0.45, 0.18)
             or (hov and std.vec(0.34, 0.34, 0.50) or std.vec(0.18, 0.20, 0.28))
    local padding = C.default_padding
    ga_win_quad_color(wid, x - C.fix_padding(padding), y - padding, x + w + C.fix_padding(padding), y + h + padding, std.vec(0.40, 0.40, 0.55))
    ga_win_quad_color(wid, x, y, x + w, y + h, col)
    ga_win_set_char_size(wid, 0.009, 0.018)
    ga_win_set_front_color(wid, std.vec(1, 1, 1))
    ga_win_txt(wid, x + 0.006, y + h * 0.5 - 0.008, label)
    ga_win_set_front_color_default(wid)
    return hov
end

function C.gets(var, d) local v = ga_get_s(var); if type(v) == "string" and v ~= "" then return v end return d end

-- current search text; tabs without the search box use the remembered one
function C.get_search(wid)
    if S.has_search then
        local s = ga_win_widget_text_input_get_text(wid)
        if type(s) == "string" then return s end
    end
    return S.search_text
end

-- "toaction" does NOT replace an existing anonymous (tocommand) bind on the
-- same event, so unbind first (else guns stay dead after build mode).
function C.bind_action(ev, action)
    ga_command('bind ' .. ev .. ' unbind')
    ga_command('bind ' .. ev .. ' toaction ' .. action)
end

-- Same binds as bind_build/bind_weapons in Game/game_creative.lua (keep in sync).
function C.set_build_mode(on)
    ga_set_b(C.MODE_VAR, on)
    if ga_exists(C.ALT_VAR) then ga_set_b(C.ALT_VAR, false) end
    -- wheel + 1-9 stay on xar's equip actions; game_creative hooks those
    -- commands while build mode is on (wheel .use events ignore anon binds)
    C.bind_action('MOUSEWHEEL_UP.use', 'PACKAGE_EQUIP_NEXT')
    C.bind_action('MOUSEWHEEL_DOWN.use', 'PACKAGE_EQUIP_PREV')
    for i = 1, C.HB_COUNT do
        C.bind_action(i .. '.downup', 'PACKAGE_EQUIP_' .. i)
    end
    if on then
        ga_command('bind MOUSE1.downup tocommand "creative_place"')
        ga_command('bind MOUSE2.downup tocommand "creative_break"')
        ga_command('bind MOUSE3.downup tocommand "creative_eyedrop"')
        ga_command('bind C.downup tocommand "creative_eyedrop"')
        ga_command('bind BACKSPACE.downup tocommands "creative_undo start" "creative_undo end"')
        ga_command('bind LALT.downup tocommands "creative_alt start" "creative_alt stop"')
        ga_command('bind RALT.downup tocommands "creative_alt start" "creative_alt stop"')
    else
        C.bind_action('MOUSE1.downup', 'PACKAGE_USE_EQUIPPED_PRIMARY')
        C.bind_action('MOUSE2.downup', 'PACKAGE_USE_EQUIPPED_SECONDARY')
        C.bind_action('C.downup', 'PACKAGE_USE_WEP_3_PRIMARY')
        ga_command('bind MOUSE3.downup unbind')
        ga_command('bind BACKSPACE.downup unbind')
        ga_command('bind LALT.downup unbind')
        ga_command('bind RALT.downup unbind')
        ga_hud_msg("Build: OFF  (mouse = weapons)", 2.0)
    end
end

function C.hb_get(i)
    local s = ga_get_s(C.HB_PREFIX .. i)
    if type(s) ~= "string" or s == "" then return nil, nil end
    local k, r = string.match(s, "^([^|]+)|(.+)$")
    return k, r
end

function C.cur_slot()
    local s = ga_get_i(C.SLOT_VAR) or 1
    if s < 1 or s > C.HB_COUNT then s = 1 end
    return s
end

function C.cur_entry()
    local k, r = C.hb_get(C.cur_slot())
    if k == nil then
        local s = ga_get_s(C.SEL_VAR)
        if type(s) == "string" and s ~= "" then return "block", s end
    end
    return k, r
end

-- Same rule as hb_pick in Game/game_creative.lua: reuse its slot, else the
-- current slot if empty, else the first empty one, else replace the current one.
function C.hb_pick(kind, raw)
    local want = kind .. "|" .. raw
    local slot = C.cur_slot()
    local target = nil
    for i = 1, C.HB_COUNT do
        if ga_get_s(C.HB_PREFIX .. i) == want then target = i break end
    end
    if target == nil then
        if C.hb_get(slot) == nil then
            target = slot
        else
            for i = 1, C.HB_COUNT do
                if C.hb_get(i) == nil then target = i break end
            end
        end
        target = target or slot
        ga_set_s(C.HB_PREFIX .. target, want)
    end
    ga_set_i(C.SLOT_VAR, target)
    ga_set_s(C.SEL_VAR, (kind == "block") and raw or "")
end

-- Pick something into the hotbar, switch to build mode and go back to the game.
function C.pick_and_build(kind, raw, label)
    C.hb_pick(kind, raw)
    C.set_build_mode(true)
    if kind == "block" then
        ga_hud_msg("Selected " .. label .. "  (L place / R break, wheel = hotbar)", 2.5)
    elseif kind == "path" then
        ga_hud_msg("Selected " .. label .. "  (L-click = use it like a " .. raw .. " ring)", 3.0)
    else
        ga_hud_msg("Selected " .. label .. "  (L place / R remove, Alt+wheel = distance)", 3.0)
    end
    ga_play_sound("menu_select")
    ga_window_pop()
end

-- not a real window: only here so the window Lua state loads it
function p.__start(wid) end
function p.__end(wid) end
function p.__on_start(wid) end
function p.__on_end(wid) end
function p.__render(wid) end
function p.__process_input(wid) end
