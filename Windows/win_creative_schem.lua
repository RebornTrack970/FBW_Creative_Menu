-- Creative menu: DECOR -> SCHEMATICS page (the button on the right of the
-- DECOR strip). Lists the schematics Game/game_creative_schem.lua keeps (it
-- publishes them in temp.creative.schem_list): click = put it in the hotbar,
-- middle-click = save it as Lua (a block script, game C.schem_export_lua),
-- R-click twice = delete it, RELOAD FILE = read the file again (e.g. after
-- copying someone's creative_schems.txt into Output/FileOut/).
-- See win_creative_core.lua for how the files share things.
creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

local LIST_VAR   = "temp.creative.schem_list"     -- "name:sx:sy:sz:blocks:ents:monsters,..."
local STATUS_VAR = "temp.creative.schem_status"   -- "" | "ok" | "noread" | "broken"
local REQ_VAR    = "temp.creative.schem_req"      -- "del <name>" | "lua <name>" | "reload" (game tick)
local NOTE_SECS  = 6.0                            -- how long "Lua saved: ..." stays on the strip
local DEL_CONFIRM = 3.0                           -- seconds for the 2nd R-click

C.dp = {
    sub    = nil,                                              -- nil | "schems"
    open   = { x = 0.795, y = 0.095, w = 0.180, h = 0.035 },   -- SCHEMATICS on the DECOR strip
    back   = { x = 0.025, y = 0.095, w = 0.200, h = 0.035 },   -- BACK on the page
    reload = { x = 0.795, y = 0.095, w = 0.180, h = 0.035 },   -- RELOAD FILE on the page
    built  = nil,                                              -- list string the page shows
}
S.schem_del = nil                    -- { name, time }: the 1st R-click of a delete
S.schem_note = nil                   -- { text, time }: what the last Lua export wrote

local list_src, list_cache = nil, {}

-- { { name, sx, sy, sz, nb, ne, nm }, ... } (sorted by the game)
function C.schem_list()
    local s = ga_exists(LIST_VAR) and ga_get_s(LIST_VAR) or ""
    if type(s) ~= "string" then s = "" end
    if s == list_src then return list_cache end
    list_src, list_cache = s, {}
    for entry in string.gmatch(s, "[^,]+") do
        local f = {}
        for part in string.gmatch(entry, "[^:]+") do f[#f + 1] = part end
        if #f >= 7 then
            list_cache[#list_cache + 1] = { name = f[1], sx = tonumber(f[2]) or 0, sy = tonumber(f[3]) or 0,
                sz = tonumber(f[4]) or 0, nb = tonumber(f[5]) or 0, ne = tonumber(f[6]) or 0,
                nm = tonumber(f[7]) or 0 }
        end
    end
    return list_cache
end

function C.schem_entry(name)
    for _, e in ipairs(C.schem_list()) do
        if e.name == name then return e end
    end
    return nil
end

-- " (7x5x6)" after a hotbar schematic's name
function C.schem_dims(name)
    local e = C.schem_entry(name)
    if e == nil then return "" end
    return " (" .. e.sx .. "x" .. e.sy .. "x" .. e.sz .. ")"
end

local function contents(e)
    local s = e.nb .. " block" .. (e.nb == 1 and "" or "s")
    if e.ne > 0 then s = s .. ", " .. e.ne .. " ent" .. (e.ne == 1 and "" or "s") end
    if e.nm > 0 then s = s .. ", " .. e.nm .. " monster" .. (e.nm == 1 and "" or "s") end
    return s
end

local function status()
    local s = ga_exists(STATUS_VAR) and ga_get_s(STATUS_VAR) or ""
    return type(s) == "string" and s or ""
end

-- Ask the game side: call it directly (windows run in the same Lua state as
-- the game scripts - xar's own windows call game modules), else leave the
-- request for its next tick. Returns true + what the call returned, or false.
local function game_req(fn, req, ...)
    local g = rawget(_G, "creative_g")
    if type(g) == "table" and type(g[fn]) == "function" then
        local ok, res = pcall(g[fn], ...)
        if ok then return true, res end
        ga_hud_msg("Schematics: " .. tostring(res), 3.0)
    end
    if not ga_exists(REQ_VAR) then ga_init_s(REQ_VAR, "") end
    ga_set_s(REQ_VAR, req)
    return false
end

-- middle mouse just went down. ga_win_mouse_pressed2(wid, n) takes FBW's own
-- button numbers = the MOUSE1 / MOUSE2 / MOUSE3 bind names: 1 = left,
-- 2 = right, 3 = middle (FBW.exe Input::MousePressedGeneral; plain
-- ga_win_mouse_pressed(wid, left) passes 1 / 2). Not SDL's 1 / 2 / 3.
local MOUSE_MIDDLE = 3
function C.mmb_pressed(wid)
    return ga_win_mouse_pressed2(wid, MOUSE_MIDDLE) or ga_win_key_pressed(wid, "C")
end

-- middle-click: save it as a Lua block script (Output/FileOut/block_schem_<name>.lua)
function C.dp.export(gi)
    local it = S.items[gi]
    if it == nil then return end
    local direct, files = game_req("schem_export_lua", "lua " .. it.raw, it.raw)
    local text
    if direct and type(files) == "table" and #files == 1 then
        text = "Lua saved: Output/FileOut/" .. files[1]
    elseif direct and type(files) == "table" and #files > 1 then
        text = "Lua saved: " .. #files .. " pieces, Output/FileOut/" .. string.gsub(files[1], "_%d+_%d+_%d+%.lua$", "_X_Y_Z.lua")
    elseif direct then
        text = nil                                  -- (failed: the game showed why)
    else
        text = "Lua: saving " .. it.raw .. " ..."
    end
    S.schem_note = text and { text = text, time = ga_get_sys_f("time.current") } or nil
    ga_play_sound(text and "menu_select" or "menu_back")
end

function C.dp.set(wid, sub)
    C.dp.sub = sub
    S.schem_del = nil
    C.rebuild(wid)
    S.page = 0
    ga_play_sound("menu_select")
end

-- grid items (C.rebuild, DECOR tab while the page is open)
function C.dp.rebuild(search)
    for _, e in ipairs(C.schem_list()) do
        if search == "" or string.find(string.upper(e.name), search, 1, true) then
            S.items[#S.items + 1] = {
                raw = e.name, label = e.name, kind = "schem", tex = "creative_schem",
                cat = "SCHEM", col = std.vec(0.15, 0.30, 0.45),
                info = e.sx .. "x" .. e.sy .. "x" .. e.sz .. ", " .. contents(e),
            }
        end
    end
    C.dp.built = list_src
end

-- the list changed (loaded, saved, deleted) while the page is open: redo it
function C.dp.poll(wid)
    if C.dp.sub ~= "schems" then return end
    C.schem_list()
    if list_src ~= C.dp.built then
        local page = S.page
        C.rebuild(wid)
        S.page = math.max(0, math.min(page, C.num_pages() - 1))
    end
end

function C.dp.choose(gi)
    local it = S.items[gi]
    if it == nil then return end
    C.pick_and_build("schem", it.raw, it.label)
end

function C.dp.del_armed(name)
    local d = S.schem_del
    return d ~= nil and d.name == name and ga_get_sys_f("time.current") - d.time <= DEL_CONFIRM
end

-- R-click: 1st arms the delete (red frame), a 2nd one within 3 s deletes
function C.dp.rclick(gi)
    local it = S.items[gi]
    if it == nil then return end
    if C.dp.del_armed(it.raw) then
        S.schem_del = nil
        game_req("schem_delete", "del " .. it.raw, it.raw)
        ga_play_sound("menu_back")
    else
        S.schem_del = { name = it.raw, time = ga_get_sys_f("time.current") }
        ga_play_sound("menu_select")
    end
end

function C.dp.strip_click(wid, cursor)
    local b, r = C.dp.back, C.dp.reload
    if C.btn_rect(cursor, b.x, b.y, b.w, b.h) then
        C.dp.set(wid, nil)
    elseif C.btn_rect(cursor, r.x, r.y, r.w, r.h) then
        game_req("schem_load", "reload")
        C.rebuild(wid)
        ga_play_sound("menu_select")
    end
end

-- the page's strip: BACK, title + count, file trouble (if any), RELOAD FILE
function C.render_schem_strip(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    local b, r = C.dp.back, C.dp.reload
    ga_win_quad_color(wid, 0.02, 0.092, 0.98, 0.133, std.vec(0.06, 0.06, 0.10))
    C.small_btn(wid, cursor, b.x, b.y, b.w, b.h, "< BACK TO DECOR", false)
    local tx = b.x + b.w + 0.03
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    local title = "SCHEMATICS (" .. #C.schem_list() .. ")"
    ga_win_txt(wid, tx, b.y + 0.008, title)
    local st = status()
    local warn = nil
    if st == "noread" then
        warn = "can't read the file back - kept until you quit"
    elseif st == "broken" then
        warn = "creative_schems.txt is damaged - not saved"
    end
    local col = std.vec(1.0, 0.45, 0.35)
    local n = S.schem_note
    if warn == nil and n ~= nil and ga_get_sys_f("time.current") - n.time <= NOTE_SECS then
        warn, col = n.text, std.vec(0.45, 1.0, 0.55)           -- what the last Lua export wrote
    end
    if warn then
        local cw = 0.0075
        ga_win_set_char_size(wid, cw, 0.015)
        ga_win_set_front_color(wid, col)
        ga_win_txt(wid, tx + #title * 0.010 + 0.02, b.y + 0.010, C.fit(warn, math.floor((r.x - 0.01 - (tx + #title * 0.010 + 0.02)) / cw)))
    end
    ga_win_set_front_color_default(wid)
    C.small_btn(wid, cursor, r.x, r.y, r.w, r.h, "RELOAD FILE", false)
end

-- not a real window: only here so the window Lua state loads it
function p.__start(wid) end
function p.__end(wid) end
function p.__on_start(wid) end
function p.__on_end(wid) end
function p.__render(wid) end
function p.__process_input(wid) end
