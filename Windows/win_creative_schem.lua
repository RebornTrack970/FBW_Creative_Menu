-- Creative menu: the SCHEMS tab. Lists the schematics
-- Game/game_creative_schem.lua keeps (it publishes them in
-- temp.creative.schem_list) on the left half; the right half is a 3D preview
-- of the hovered one (the last hovered one stays): its blocks with their
-- textures and its ents / monsters as models (game C.schem_holo /
-- C.schem_ent_meshes - windows and game scripts share one Lua state), turned
-- with the camera of win_creative_view3d.lua.
-- Click = put it in the hotbar, middle-click = save it as Lua (a block
-- script, game C.schem_export_lua), R-click twice = delete it, RELOAD FILE =
-- read the file again (e.g. after copying someone's creative_schems.txt into
-- Output/FileOut/).
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
    reload = { x = 0.795, y = 0.095, w = 0.180, h = 0.035 },   -- RELOAD FILE on the strip
    built  = nil,                                              -- list string the tab shows
}
S.schem_del = nil                    -- { name, time }: the 1st R-click of a delete
S.schem_note = nil                   -- { text, time }: what the last Lua export wrote
S.schem_view = nil                   -- name of the schematic in the 3D preview

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
-- No C key here (unlike in the world): this page has the search box, which
-- gets every letter, so C would also type "c" into it.
local MOUSE_MIDDLE = 3
function C.mmb_pressed(wid)
    return ga_win_mouse_pressed2(wid, MOUSE_MIDDLE) == true
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

-- grid items (C.rebuild, SCHEMS tab)
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

-- the list changed (loaded, saved, deleted) while the tab is open: redo it
function C.dp.poll(wid)
    if S.cur_tab ~= C.TAB_SCHEMS then return end
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
    local r = C.dp.reload
    if C.btn_rect(cursor, r.x, r.y, r.w, r.h) then
        game_req("schem_load", "reload")
        C.rebuild(wid)
        ga_play_sound("menu_select")
    end
end

-- the tab's strip: title + count, file trouble (if any), RELOAD FILE
local function render_schem_strip(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    local r = C.dp.reload
    ga_win_quad_color(wid, 0.02, 0.092, 0.98, 0.133, std.vec(0.06, 0.06, 0.10))
    local tx = 0.025
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    local title = "SCHEMATICS (" .. #C.schem_list() .. ")"
    ga_win_txt(wid, tx, r.y + 0.008, title)
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
        ga_win_txt(wid, tx + #title * 0.010 + 0.02, r.y + 0.010, C.fit(warn, math.floor((r.x - 0.01 - (tx + #title * 0.010 + 0.02)) / cw)))
    end
    ga_win_set_front_color_default(wid)
    C.small_btn(wid, cursor, r.x, r.y, r.w, r.h, "RELOAD FILE", false)
end

-------------------------------------------------------------------------------
-- The tab: grid (left half), 3D preview (right half), strip
-------------------------------------------------------------------------------
local cam = nil                                  -- C.cam_new(), made on first use
local PREVIEW_X, PREVIEW_Y = 0.75, 0.48          -- centre of the preview
local GIZMO_X, GIZMO_Y     = 0.935, 0.235        -- bottom right of the preview
local INFO_Y               = 0.150               -- name / size / contents line
local preview_err_shown    = false

-- the game's schematic table (+ the game namespace), or nil
local function game_schem(name)
    local g = rawget(_G, "creative_g")
    if type(g) ~= "table" or type(g.schem_get) ~= "function" or type(g.schem_holo) ~= "function" then
        return nil, nil
    end
    local ok, sch = pcall(g.schem_get, name)
    if ok and type(sch) == "table" then return sch, g end
    return nil, nil
end

-- a drag starts only on the preview (right of the grid, above the info line)
local function on_preview(cursor)
    local gx1 = C.X0 + S.COLS * S.CW + 0.01
    return cursor.x > gx1 and cursor.x < 0.99 and cursor.y > INFO_Y + 0.035 and cursor.y < 0.80
       and not C.cam_on_gizmo(cursor, GIZMO_X, GIZMO_Y)
end

-- which schematic to show: the hovered tile, else the last one shown (if it
-- is still in the list), else the first one
local function view_name(wid)
    local gi = C.hovered_index(ga_win_get_cursor_pos(wid))
    if gi >= 1 and S.items[gi] then S.schem_view = S.items[gi].raw end
    if S.schem_view ~= nil then
        for _, it in ipairs(S.items) do
            if it.raw == S.schem_view then return S.schem_view end
        end
    end
    S.schem_view = S.items[1] and S.items[1].raw or nil
    return S.schem_view
end

-- blocks: the ghost's cubes (visible ones, real textures; types without a
-- known texture = white tinted per type), drawn solid; ents: their models
local function render_preview(sch, g)
    local depth = 0
    local ok, err = pcall(function()
        ga_render_push_matrix(); depth = 1
        ga_render_matrix_translated(PREVIEW_X, PREVIEW_Y, 0)
        C.cam_apply(cam, sch.sx, sch.sy, sch.sz)
        ga_render_set_depth_test_enabled(false)              -- faint box: its size
        ga_render_push_matrix(); depth = 2
        ga_render_matrix_scaled(sch.sx, sch.sy, sch.sz)
        ga_render_mesh_with_tex_alpha_no_lighting("creative_block", "creative_white", 0.08)
        ga_render_pop_matrix(); depth = 1
        ga_render_set_depth_test_enabled(true)
        for _, grp in ipairs(g.schem_holo(sch).groups) do
            if grp.tex == "creative_white" then
                ga_render_color(std.vec(grp.col[1], grp.col[2], grp.col[3]))
            else
                ga_render_color(std.vec(1.0, 1.0, 1.0))
            end
            local c = grp.cells
            for i = 1, #c, 3 do
                ga_render_push_matrix(); depth = 2
                ga_render_matrix_translated(c[i], c[i + 1], c[i + 2])
                ga_render_mesh_with_tex("creative_block", grp.tex)
                ga_render_pop_matrix(); depth = 1
            end
        end
        ga_render_color(std.vec(1.0, 1.0, 1.0))
        if type(g.schem_ent_meshes) == "function" then
            g.schem_ent_meshes(sch, 0, 0, 0, nil, true)         -- solid, stand-ins for the rest
        end
    end)
    for _ = 1, depth do ga_render_pop_matrix() end
    ga_render_color(std.vec(1.0, 1.0, 1.0))
    ga_render_set_depth_test_enabled(false)
    if not ok and not preview_err_shown then
        preview_err_shown = true                             -- once, not every frame
        ga_console_print("creative schematic preview error: " .. tostring(err))
    end
end

local function render_info(wid, name, has_3d)
    local e = C.schem_entry(name)
    if e == nil then return end
    local gx1 = C.X0 + S.COLS * S.CW + 0.02
    local cw = 0.009
    local text = e.name .. "   " .. e.sx .. "x" .. e.sy .. "x" .. e.sz .. "   " .. contents(e)
    if not has_3d then text = text .. "   (no 3D preview)" end
    text = C.fit(text, math.floor((0.98 - gx1) / cw))
    ga_win_set_char_size(wid, cw, 0.018)
    ga_win_set_front_color(wid, std.vec(0.75, 0.90, 1.0))
    local x = math.max(gx1, PREVIEW_X - #text * cw * 0.5)
    ga_win_txt(wid, x, INFO_Y, text)
    ga_win_set_front_color_default(wid)
end

function C.render_schem_tab(wid)
    S.COLS = math.max(1, math.floor((C.GRID_W + C.GAPX) / S.CW)) // 2   -- left half
    S.PER_PAGE = S.COLS * S.ROWS
    cam = cam or C.cam_new()
    C.cam_input(wid, cam, on_preview)

    local name = view_name(wid)
    local sch, g = nil, nil
    if name ~= nil then sch, g = game_schem(name) end
    if sch ~= nil then render_preview(sch, g) end

    C.render_grid_tab(wid, "schem")              -- (its hover tip goes over the preview)
    ga_win_set_screen_coord_mode(wid, "screen")
    if name ~= nil then
        render_info(wid, name, sch ~= nil)
        if sch ~= nil then C.cam_gizmo(wid, cam, GIZMO_X, GIZMO_Y) end
    end
    render_schem_strip(wid)
end

-- not a real window: only here so the window Lua state loads it
function p.__start(wid) end
function p.__end(wid) end
function p.__on_start(wid) end
function p.__on_end(wid) end
function p.__render(wid) end
function p.__process_input(wid) end
