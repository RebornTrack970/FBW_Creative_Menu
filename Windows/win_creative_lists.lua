-- Creative menu: the grid tabs (BLOCKS, ENTITIES, INTERACT + its Trophies
-- page, TELEPORT, DECOR): item lists, picking, their control strips and
-- input. See win_creative_core.lua for how the files share things.
creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

-- INTERACT tab order: by type, then natural order inside a type (gold_2
-- before gold_10). No headers, just the order. Rules are checked top to
-- bottom (first match wins); the number is where that type goes in the list.
-- Anything unmatched goes last.
local isort = {}
isort.ORDER = {
    { "^bent_key_", 1 }, { "^bent_buy_blue_key$", 1 },                    -- keys
    { "^bent_ammo_", 2 },                                                 -- ammo
    { "^bent_health_", 3 },                                               -- health
    { "^bent_armor_", 4 }, { "^bent_shield$", 4 },                        -- armor / shield
    { "^bent_gold_", 5 },                                                 -- gold
    { "^bent_xp", 6 }, { "_stacking$", 6 },                               -- xp / powerups
    { "^bent_upgrade_station", 9 }, { "^bent_upgrade_telekinesis$", 9 },  -- (shops, before the next rule)
    { "^bent_upgrade_", 7 },                                              -- upgrade pickups
    { "^bent_weapon_mod_", 8 },                                           -- weapon mods
    { "^bent_buy_", 9 }, { "^bent_black_market$", 9 }, { "^bent_sell_station_", 9 },
    { "^bent_cheap_", 9 }, { "^bent_pay_toll", 9 }, { "^bent_sleep", 9 }, -- shops / services
    { "respawn", 10 }, { "^bent_base_save$", 10 }, { "waypoint", 10 }, { "^bent_bookmark$", 10 },
    { "^bent_base_ring_", 11 },                                           -- rings
    { "door", 12 }, { "^bent_arcade_", 12 }, { "control_panel$", 12 },    -- doors / switches
    { "^bent_genesis_marker_", 13 }, { "^bent_base_txt$", 13 },           -- markers / text boxes
    { "trophy", 14 },                                                     -- trophies
}

function isort.rank(raw)
    for _, rule in ipairs(isort.ORDER) do
        if string.find(raw, rule[1]) then return rule[2] end
    end
    return 99
end

-- "gold_10" -> { "gold_", 10 }; numbers compare as numbers
isort.cache = {}
function isort.parts(s)
    local t = isort.cache[s]
    if t then return t end
    t = {}
    for txt, num in string.gmatch(s, "(%D*)(%d*)") do
        if txt ~= "" then t[#t + 1] = txt end
        if num ~= "" then t[#t + 1] = tonumber(num) end
    end
    isort.cache[s] = t
    return t
end

function isort.nat_less(a, b)
    local pa, pb = isort.parts(a), isort.parts(b)
    for i = 1, math.min(#pa, #pb) do
        local x, y = pa[i], pb[i]
        if x ~= y then
            if type(x) == type(y) then return x < y end
            return type(x) == "number"          -- digits before letters
        end
    end
    return #pa < #pb
end

function isort.less(a, b)
    local ra, rb = isort.rank(a.raw), isort.rank(b.raw)
    if ra ~= rb then return ra < rb end
    return isort.nat_less(a.raw, b.raw)
end

local function enum_names(fn, prefix)
    local out, seen = {}, {}
    local arr = fn(prefix)
    if arr then
        for _, v in ipairs(arr) do
            local nm = v
            if type(v) == "table" then nm = v.name end
            if type(nm) == "string" and not seen[nm] then
                seen[nm] = true
                out[#out + 1] = nm
            end
        end
    end
    table.sort(out)
    return out
end

local function csv_list(var)
    local out = {}
    local s = ga_get_s(var)
    if type(s) == "string" then
        for w in string.gmatch(s, "[^,]+") do out[#out + 1] = w end
    end
    return out
end
local function csv_save(var, t) ga_set_s(var, table.concat(t, ",")) end
local function list_has(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end

local function is_fav(raw) return list_has(csv_list(C.FAV_VAR), raw) end
local function fav_toggle(raw)
    local t = csv_list(C.FAV_VAR)
    for i, x in ipairs(t) do
        if x == raw then table.remove(t, i); csv_save(C.FAV_VAR, t); return false end
    end
    t[#t + 1] = raw; csv_save(C.FAV_VAR, t); return true
end
local function add_recent(raw)
    local t = csv_list(C.REC_VAR)
    for i, x in ipairs(t) do if x == raw then table.remove(t, i); break end end
    table.insert(t, 1, raw)
    while #t > 24 do t[#t] = nil end
    csv_save(C.REC_VAR, t)
end

local rebuild_decor     -- defined with the DECOR tab code below

-- INTERACT has one extra entry, "Trophies", which opens a page listing every
-- trophy instead of the interactables (BACK returns). bent_secret_trophy is
-- not listed by itself: a secret trophy needs its st_* name from that page.
-- tp.rebuild / tp.set are defined with the DECOR tab code below.
C.tp = {
    entry = "@trophy",                                 -- the INTERACT entry
    sub   = nil,                                       -- nil | "trophies"
    back  = { x = 0.025, y = 0.095, w = 0.20, h = 0.035 },   -- BACK button
}

function C.rebuild(wid)
    S.items = {}
    local search = string.upper(C.get_search(wid))

    if S.cur_tab == C.TAB_BLOCKS then
        local fav_set, rec_list
        if S.view_mode == "FAV" then
            fav_set = {}
            for _, v in ipairs(csv_list(C.FAV_VAR)) do fav_set[v] = true end
        elseif S.view_mode == "RECENT" then
            rec_list = csv_list(C.REC_VAR)
        end

        local names = enum_names(ga_get_block_names_with_prefix, "")
        if #names == 0 then names = enum_names(ga_get_block_names_with_prefix, "XAR_") end

        if S.view_mode == "RECENT" and rec_list then
            for _, nm in ipairs(rec_list) do
                local bad = block_wiki_bad_blocks[nm]
                local match = (search == "") or string.find(string.upper(nm), search, 1, true)
                if (not bad) and match then
                    local c = C.clean_name(nm)
                    local cat = C.category_of(c)
                    S.items[#S.items + 1] = { raw = nm, label = c, cat = cat, col = C.cat_color(cat) }
                end
            end
        else
            for _, nm in ipairs(names) do
                local bad = block_wiki_bad_blocks[nm]
                local match = (search == "") or string.find(string.upper(nm), search, 1, true)
                local mode_ok = true
                if fav_set then mode_ok = (fav_set[nm] == true) end
                if (not bad) and match and mode_ok then
                    local c = C.clean_name(nm)
                    local cat = C.category_of(c)
                    S.items[#S.items + 1] = { raw = nm, label = c, cat = cat, col = C.cat_color(cat) }
                end
            end
        end

        if S.sort_mode == "CATEGORY" then
            table.sort(S.items, function(a, b)
                if a.cat ~= b.cat then return a.cat < b.cat end
                return a.label < b.label
            end)
        end

    elseif S.cur_tab == C.TAB_WEAPONS then
        for n = 0, 9 do
            local nm = "Weapon " .. n
            if game_wep_modes and game_wep_modes.get_wep_name then
                nm = game_wep_modes.get_wep_name(n)
            end
            S.items[#S.items + 1] = { raw = n, label = nm, cat = "WEP", col = std.vec(0.35, 0.25, 0.15) }
        end

    elseif S.cur_tab == C.TAB_ITEMS then
        S.items = {}

    elseif S.cur_tab == C.TAB_BUFFS then
        S.items = {}

    elseif S.cur_tab == C.TAB_ENTITIES then
        local names = enum_names(ga_get_ment_names_with_prefix, "")
        if #names == 0 then names = enum_names(ga_get_ment_names_with_prefix, "ment_") end
        for _, ent in ipairs(names) do
            if string.sub(ent, 1, 13) ~= "ment_picture_" then
                local label = C.ent_label(ent)          -- the in-game name ("Ogre")
                local match = (search == "") or string.find(string.upper(label .. " " .. ent), search, 1, true)
                if match then
                    S.items[#S.items + 1] = { raw = ent, label = label, cat = "ENT", col = std.vec(0.30, 0.20, 0.35) }
                end
            end
        end

    elseif S.cur_tab == C.TAB_INTERACT and C.tp.sub == "trophies" then
        C.tp.rebuild(search)

    elseif S.cur_tab == C.TAB_INTERACT then
        local names = enum_names(ga_get_bent_names_with_prefix, "")
        if #names == 0 then names = enum_names(ga_get_bent_names_with_prefix, "bent_") end
        names[#names + 1] = C.tp.entry
        for _, raw in ipairs(names) do
            local label = C.INTERACT_LABEL[raw] or C.clean_bent_name(raw)
            local tex   = (raw == C.tp.entry) and "secret_trophy" or C.bent_tex(raw)
            local hay   = string.upper(label .. " " .. raw)
            local match = (search == "") or string.find(hay, search, 1, true)
            if match and raw ~= "bent_secret_trophy" then
                S.items[#S.items + 1] = {
                    raw = raw, label = label, cat = "INT",
                    col = std.vec(0.18, 0.30, 0.30),
                    tex = tex,
                }
            end
        end
        table.sort(S.items, isort.less)

    elseif S.cur_tab == C.TAB_DECOR then
        rebuild_decor(search)

    elseif S.cur_tab == C.TAB_TELEPORT then
        if game_base_wp_system and game_base_wp_system.get_wps_filtered then
            local nodes = game_base_wp_system.get_wps_filtered(false, "")
            if nodes then
                for _, node in ipairs(nodes) do
                    local full = game_base_wp_system.get_full_wp_name(node)
                    local match = (search == "") or string.find(string.upper(full), search, 1, true)
                    if match then
                        local path = node.path or ""
                        local handle = nil
                        if game_base_wp_system.convert_path_to_handle then
                            handle = game_base_wp_system.convert_path_to_handle(path)
                        end
                        local col = std.vec(0.20, 0.35, 0.45)
                        if node.last_travel_failed then col = std.vec(0.50, 0.15, 0.15) end
                        if node.in_only then col = std.vec(0.50, 0.50, 0.15) end
                        S.items[#S.items + 1] = {
                            raw = tostring(handle or -1),
                            label = full,
                            cat = "WP",
                            col = col,
                        }
                    end
                end
            end
        end
    end
    S.page = 0
end

function C.num_pages()
    if #S.items == 0 then return 1 end
    return math.floor((#S.items - 1) / S.PER_PAGE) + 1
end

function C.cell_rect(i)
    local col = i % S.COLS
    local row = math.floor(i / S.COLS)
    local minx = C.X0 + col * S.CW
    local maxy = C.Y0 - row * S.CH
    return minx, maxy - (S.CH - C.GAPY), minx + (S.CW - C.GAPX), maxy
end

function C.hovered_index(cursor)
    for i = 0, S.PER_PAGE - 1 do
        local minx, miny, maxx, maxy = C.cell_rect(i)
        if cursor.x >= minx and cursor.x <= maxx and cursor.y >= miny and cursor.y <= maxy then
            local gi = S.page * S.PER_PAGE + i + 1
            if gi <= #S.items then return gi, i end
        end
    end
    return -1, -1
end

local function choose_block(gi)
    local it = S.items[gi]
    if it == nil then return end
    add_recent(it.raw)
    C.pick_and_build("block", it.raw, it.label)
end

local function choose_weapon(gi)
    local it = S.items[gi]
    if it == nil then return end
    local n = tonumber(it.raw)
    if n ~= nil then S.sel_weapon = n end
    ga_play_sound("menu_select")
end

-- Entities / interactables / decor are placed in the world by game_creative.lua
-- (L-click at the aim point, Alt+wheel = distance, R-click removes).
local function choose_entity(gi)
    local it = S.items[gi]
    if it == nil then return end
    C.pick_and_build("ment", it.raw, it.label)
end

function C.tp.set(wid, sub)
    C.tp.sub = sub
    C.rebuild(wid)
    S.page = 0
    ga_play_sound("menu_select")
end

local function choose_interactable(gi, wid)
    local it = S.items[gi]
    if it == nil then return end
    if it.raw == C.tp.entry then
        C.tp.set(wid, "trophies")             -- open the trophy page
    elseif C.AMOUNT_BENTS[it.raw] or C.PARAM_BENTS[it.raw] then
        -- needs an amount (XP, seconds, ammo, price) and / or a text param
        -- (combo, area, var, upgrade): put it in the hotbar but keep the menu
        -- open on its settings strip. An amount (else a text param) field
        -- starts selected: type it, Enter = back to the game (Esc / clicking
        -- elsewhere keeps the menu open). Choice params: < > in the strip.
        local raw, label = it.raw, it.label
        local a, pb = C.AMOUNT_BENTS[raw], C.PARAM_BENTS[raw]
        C.hb_pick("bent", raw)
        C.set_build_mode(true)
        local function done()
            ga_hud_msg("Selected " .. label .. C.bent_suffix(raw)
                .. "  (L place / R remove, Alt+wheel = distance)", 3.0)
            ga_window_pop()
        end
        if a ~= nil then
            C.num_edit_open("amt:" .. raw, C.amount_get(raw),
                function(v) C.amount_set(raw, v) end, done, a.neg)
        elseif pb.kind == "text" then
            C.num_edit_open("txt:" .. raw, C.param_get(raw),
                function(s) C.param_set(raw, s) end, done, false, true)
        end
        ga_play_sound("menu_select")
    elseif it.kind ~= nil then
        C.pick_and_build(it.kind, it.raw, it.label)     -- trophy page: trophy | secret
    else
        C.pick_and_build("bent", it.raw, it.label)
    end
end

local function choose_teleport(gi)
    local it = S.items[gi]
    if it == nil then return end
    local handle = tonumber(it.raw)
    if handle == nil then return end
    game_base_wp_system.teleport_target_only(handle)
    ga_hud_msg("warping to " .. it.label, 2.0)
    ga_play_sound("menu_select")
    ga_window_pop()
end

-------------------------------------------------------------------------------
-- DECOR tab: pictures. Trophies are on their own page, opened from the
-- "Trophies" entry of the INTERACT tab (tp.rebuild).
--
-- Pictures are placed as the basic ent bent_creative_picture
-- (BasicEnts/bent_creative_picture.lua), which draws a picture_* texture on
-- Meshes/creative_picture.obj. xar's own ment_picture_* ments were used
-- before, but they are world-gen props and did not survive their chunk being
-- unloaded/saved (see Game/game_creative.lua).
--
-- Trophies are the block block_xar_trophy with block var api_name; touching
-- it calls game_trophy.pickup(api_name). Every regular trophy has a matching
-- trophy_<api_name> texture, which is how we list them. Secret trophies are
-- bent_secret_trophy with a string param (st_* name).
-------------------------------------------------------------------------------

local function set_of(t) local o = {} for _, v in ipairs(t) do o[v] = true end return o end

-- (picture sizing / facing + trophy placement live in Game/game_creative.lua)
local DECOR_SIZES = {
    { label = "S",  scale = 0.6 },
    { label = "M",  scale = 1.0 },
    { label = "L",  scale = 1.8 },
    { label = "XL", scale = 3.0 },
}

local function secret_trophy_names()
    local out = {}
    if game_secret_trophy and game_secret_trophy.get_all then
        local ok, all = pcall(game_secret_trophy.get_all)
        if ok and type(all) == "table" then
            for k, _ in pairs(all) do
                if type(k) == "string" then out[#out + 1] = k end
            end
        end
    end
    table.sort(out)
    return out
end

local function search_add(search, it)
    local hay = string.upper(it.label .. " " .. it.raw)
    if search == "" or string.find(hay, search, 1, true) then S.items[#S.items + 1] = it end
end

rebuild_decor = function(search)
    C.ensure_tex_set()
    local pics = {}
    for nm, _ in pairs(C.get_tex_set()) do
        if string.sub(nm, 1, 8) == "picture_" then pics[#pics + 1] = nm end
    end
    table.sort(pics)
    for _, nm in ipairs(pics) do
        search_add(search, { raw = nm, kind = "picture", tex = nm, cat = "PIC",
              label = C.nice_name(string.sub(nm, 9)), col = std.vec(0.2, 0.2, 0.2) })
    end
end

-- INTERACT -> "Trophies" page: every regular trophy (one trophy_<api> texture
-- each), then the secret ones
C.tp.rebuild = function(search)
    C.ensure_tex_set()
    local trophies = {}
    for nm, _ in pairs(C.get_tex_set()) do
        if string.sub(nm, 1, 7) == "trophy_" and nm ~= "trophy_do_not_have" then
            trophies[#trophies + 1] = nm
        end
    end
    table.sort(trophies)
    for _, nm in ipairs(trophies) do
        local api = string.sub(nm, 8)
        search_add(search, { raw = api, kind = "trophy", tex = nm, cat = "TROPHY",
              label = "Trophy: " .. C.nice_name(api), col = std.vec(0.3, 0.25, 0.1) })
    end
    for _, st in ipairs(secret_trophy_names()) do
        search_add(search, { raw = st, kind = "secret", tex = "secret_trophy", cat = "SECRET",
              label = "Secret trophy: " .. C.nice_name((string.gsub(st, "^st_", ""))), col = std.vec(0.3, 0.1, 0.3) })
    end
end

-- point in front of the camera, dist units away
local function point_ahead(dist)
    local off  = ga_get_viewer_offset()
    local look = ga_get_sys_v("game.player.camera.look")
    return std.vec(off.x + look.x * dist, off.y + look.y * dist, off.z + look.z * dist), look
end

local function decor_dist()
    local d = ga_get_i(C.D_DIST)
    if d < 1 then d = 1 end
    if d > C.DIST_MAX then d = C.DIST_MAX end
    return d
end

local function remove_pictures_near_crosshair()
    local level = ga_get_viewer_level()
    local pos = point_ahead(decor_dist())
    local n = 0
    -- pictures placed by this mod are basic ents (bent_creative_picture)
    local okb, bents = pcall(ga_bent_sphere_query, level, pos, 8.0)
    if okb and type(bents) == "table" then
        for _, v in pairs(bents) do
            if v.bp ~= nil and ga_bent_get_type(level, v.bp) == "bent_creative_picture" then
                ga_bent_remove_perm(level, v.bp)
                n = n + 1
            end
        end
    end
    -- older ones were ment_picture_* ments
    local found = ga_ment_sphere_query and ga_ment_sphere_query(level, level - 5, level, pos, 8.0)
    if type(found) == "table" then
        for _, v in pairs(found) do
            local id = v.inst_id
            local t = id and ga_ment_get_type(id)
            if type(t) == "string" and string.sub(t, 1, 13) == "ment_picture_" then
                ga_ment_remove(id)
                n = n + 1
            end
        end
    end
    ga_hud_msg("removed " .. n .. " picture(s) near crosshair", 2.0)
end

local function choose_decor(gi)
    local it = S.items[gi]
    if it == nil then return end
    C.pick_and_build(it.kind, it.raw, it.label)   -- kind = picture | trophy | secret
end

-- DECOR control strip: one layout shared by render + input
local function decor_strip_layout(cb)
    local sy, sh = 0.095, 0.035
    local x = 0.025
    local function btn(id, w, label, active, group)
        cb(id, x, sy, w, sh, label, active, group)
        x = x + w + 0.005
    end
    local cur = ga_get_i(C.D_SIZE)
    for i, s in ipairs(DECOR_SIZES) do
        btn("size" .. i, 0.032, s.label, cur == i, i == 1 and "PIC SIZE" or nil)
    end
    x = x + 0.020
    btn("d_minus", 0.030, "-", false, "DIST")
    cb("d_val", x, sy, 0.030, sh, tostring(decor_dist()), false, nil)
    x = x + 0.035
    btn("d_plus",  0.030, "+", false, nil)
    x = x + 0.020
    btn("snap",    0.070, "SNAP", ga_get_b(C.D_SNAP), "FACING")
    x = x + 0.020
    btn("remove",  0.190, "REMOVE PICS HERE", false, nil)
end

-- INTERACT settings strip: the hotbar's current entry when it takes an amount
-- (C.AMOUNT_BENTS) and / or a text param (C.PARAM_BENTS), else nil
local function strip_target()
    local kind, raw = C.cur_entry()
    if kind == "bent" and raw ~= nil and (C.AMOUNT_BENTS[raw] or C.PARAM_BENTS[raw]) then return raw end
    return nil
end

-- text param block starting at x0: cb(id, x, y, w, h, label)
--   text:   "ptext" (the field)
--   choice: "prev" <  |  "pval" (the value)  |  "next" >
local function param_strip_layout(raw, x0, cb)
    local sy, sh = 0.095, 0.035
    local p = C.PARAM_BENTS[raw]
    if p.kind == "text" then
        cb("ptext", x0, sy, 0.97 - x0, sh)
    else
        local vw = math.min(0.36, 0.97 - x0 - 0.075)
        cb("prev", x0, sy, 0.030, sh, "<")
        cb("pval", x0 + 0.037, sy, vw, sh)
        cb("next", x0 + 0.044 + vw, sy, 0.030, sh, ">")
    end
end

-- where the param block starts (right of the amount controls, if any)
local function param_x0(raw)
    if C.AMOUNT_BENTS[raw] == nil then return 0.025 end
    return 0.245 + 0.065 * #C.AMOUNT_BENTS[raw].presets + 0.015
end

-- one layout for render + input: cb(id, x, y, w, h, label, preset_value)
local function amount_strip_layout(raw, cb)
    local sy, sh = 0.095, 0.035
    cb("minus", 0.025, sy, 0.030, sh, "-")
    cb("value", 0.062, sy, 0.126, sh)
    cb("plus",  0.195, sy, 0.030, sh, "+")
    local x = 0.245
    for i, n in ipairs(C.AMOUNT_BENTS[raw].presets) do
        cb("p" .. i, x, sy, 0.060, sh, C.fmt_short(n), n)
        x = x + 0.065
    end
    return x
end

-- - / + step: Ctrl 10, Shift 1K, Ctrl+Shift 10K, nothing held = the type's
-- own step (100 XP / gold, 10 sec / ammo).
-- NO Alt: ga_win_key_down only knows the window key table (FBW.exe
-- StringToDKEY: ESC SPACE arrows LCTRL RCTRL TAB GRAVE BACKSLASH BACKSPACE
-- ENTER CAPSLOCK LSHIFT RSHIFT MINUS EQUALS brackets COMMA PERIOD SLASH
-- SEMICOLON QUOTE HOME END DELETE, letters, digits); any other name, e.g.
-- "LALT", is a HARD USER ERROR that quits the game.
local function key_held(l, r) return ga_win_key_down(l) or ga_win_key_down(r) end
local function amount_step(a)
    local ctrl  = key_held("LCTRL", "RCTRL")
    local shift = key_held("LSHIFT", "RSHIFT")
    if ctrl and shift then return 10000 end
    if shift then return 1000 end
    if ctrl then return 10 end
    return a.step
end

local function amount_strip_click(raw, cursor)
    local a = C.AMOUNT_BENTS[raw]
    local hit = nil
    amount_strip_layout(raw, function(id, x, y, w, h, label, n)
        if hit == nil and id ~= "value" and C.btn_rect(cursor, x, y, w, h) then hit = { id = id, n = n } end
    end)
    if hit == nil then return end
    local v, step = C.amount_get(raw), amount_step(a)
    if hit.id == "minus" then v = a.neg and (v - step) or math.max(0, v - step)
    elseif hit.id == "plus" then v = v + step
    else v = hit.n end
    C.amount_set(raw, v)
    ga_play_sound("menu_select")
end

local function param_strip_click(raw, cursor)
    local hit = nil
    param_strip_layout(raw, param_x0(raw), function(id, x, y, w, h)
        if hit == nil and (id == "prev" or id == "next") and C.btn_rect(cursor, x, y, w, h) then hit = id end
    end)
    if hit == nil then return end
    C.param_cycle(raw, (hit == "next") and 1 or -1)
    ga_play_sound("menu_move")
end

local function decor_strip_click(id)
    if string.sub(id, 1, 4) == "size" then ga_set_i(C.D_SIZE, tonumber(string.sub(id, 5)) or 2)
    elseif id == "d_minus" then ga_set_i(C.D_DIST, math.max(1, decor_dist() - 1))
    elseif id == "d_plus" then ga_set_i(C.D_DIST, math.min(60, decor_dist() + 1))
    elseif id == "snap" then ga_toggle_b(C.D_SNAP)
    elseif id == "remove" then remove_pictures_near_crosshair()
    else return false end
    return true
end

-- grid tabs: page wheel, click = pick, right click = favourite (BLOCKS)
function C.grid_input(wid)

    if S.cur_tab == C.TAB_BLOCKS or S.cur_tab == C.TAB_ENTITIES
       or S.cur_tab == C.TAB_INTERACT or S.cur_tab == C.TAB_TELEPORT or S.cur_tab == C.TAB_DECOR then
        local np = C.num_pages()
        if ga_win_mouse_wheel_down(wid) or ga_win_key_pressed_or_spammed(wid, "DOWN", 1.0, 0.05) then
            S.page = S.page + 1
        end
        if ga_win_mouse_wheel_up(wid) or ga_win_key_pressed_or_spammed(wid, "UP", 1.0, 0.05) then
            S.page = S.page - 1
        end
        if S.page < 0 then S.page = np - 1 end
        if S.page >= np then S.page = 0 end

        if ga_win_mouse_pressed(wid, true) then
            local cursor = ga_win_get_cursor_pos(wid)
            local gi = C.hovered_index(cursor)
            if gi >= 1 then
                if S.cur_tab == C.TAB_BLOCKS then
                    choose_block(gi)
                elseif S.cur_tab == C.TAB_WEAPONS then
                    choose_weapon(gi)
                elseif S.cur_tab == C.TAB_ENTITIES then
                    choose_entity(gi)
                elseif S.cur_tab == C.TAB_INTERACT then
                    choose_interactable(gi, wid)
                elseif S.cur_tab == C.TAB_TELEPORT then
                    choose_teleport(gi)
                elseif S.cur_tab == C.TAB_DECOR then
                    choose_decor(gi)
                end
            end
        end

        if S.cur_tab == C.TAB_BLOCKS then
            local ok_rclick, rclick = ga_win_mouse_pressed(wid, false)
            if ok_rclick and rclick then
                local cursor = ga_win_get_cursor_pos(wid)
                local gi = C.hovered_index(cursor)
                if gi >= 1 and S.items[gi] then
                    local was = fav_toggle(S.items[gi].raw)
                    ga_hud_msg(was and ("Favorited: " .. S.items[gi].label) or ("Unfavorited: " .. S.items[gi].label), 1.5)
                    ga_play_sound("menu_select")
                end
            end
        end
    end

end

-- control strip under the grid of each grid tab
function C.strip_input(wid)

    if ga_win_mouse_pressed(wid, true) then
        local cursor = ga_win_get_cursor_pos(wid)
        local sy = 0.095
        local sh = 0.035

        if S.cur_tab == C.TAB_BLOCKS then
            local vx = 0.025
            local vw = 0.065
            if C.btn_rect(cursor, vx, sy, vw, sh) then
                S.view_mode = "ALL"; C.rebuild(wid); ga_play_sound("menu_select")
            end
            vx = vx + vw + 0.005
            if C.btn_rect(cursor, vx, sy, vw, sh) then
                S.view_mode = "FAV"; C.rebuild(wid); ga_play_sound("menu_select")
            end
            vx = vx + vw + 0.005
            if C.btn_rect(cursor, vx, sy, vw + 0.01, sh) then
                S.view_mode = "RECENT"; C.rebuild(wid); ga_play_sound("menu_select")
            end

            local sx = 0.33
            local sw = 0.065
            if C.btn_rect(cursor, sx, sy, sw, sh) then
                S.sort_mode = "NAME"; C.rebuild(wid); ga_play_sound("menu_select")
            end
            sx = sx + sw + 0.005
            if C.btn_rect2(cursor, sx, sy, sw + 0.02, sh) then
                S.sort_mode = "CATEGORY"
                C.rebuild(wid)
            end

            local bx = 0.52
            local bw = 0.060
            if C.btn_rect2(cursor, bx, sy, bw, sh) then
                ga_set_s(C.BR_SHAPE, "single")
                ga_set_i(C.BR_SIZE, 0)
            end
            bx = bx + bw + 0.005
            if C.btn_rect2(cursor, bx, sy, bw, sh) then
                ga_set_s(C.BR_SHAPE, "cube")
                if ga_get_i(C.BR_SIZE) < 1 then ga_set_i(C.BR_SIZE, 1) end
            end
            bx = bx + bw + 0.005
            if C.btn_rect2(cursor, bx, sy, bw + 0.005, sh) then
                ga_set_s(C.BR_SHAPE, "sphere")
                if ga_get_i(C.BR_SIZE) < 1 then ga_set_i(C.BR_SIZE, 1) end
            end

            local bsx = 0.77
            local bsw = 0.035
            if C.btn_rect2(cursor, bsx, sy, bsw, sh) then
                local s = ga_get_i(C.BR_SIZE)
                if s > 0 then ga_set_i(C.BR_SIZE, s - 1) end
            end
            bsx = bsx + bsw + 0.035
            if C.btn_rect2(cursor, bsx, sy, bsw, sh) then
                local s = ga_get_i(C.BR_SIZE)
                if s < 10 then ga_set_i(C.BR_SIZE, s + 1) end
            end

        elseif S.cur_tab == C.TAB_ENTITIES then
            local ex = 0.025
            local ew = 0.030
            if C.btn_rect2(cursor, ex, sy, ew, sh) then
                local c = ga_get_i(C.E_COUNT)
                if c > 1 then ga_set_i(C.E_COUNT, c - 1) end
            end
            ex = ex + ew + 0.035
            if C.btn_rect2(cursor, ex, sy, ew, sh) then
                local c = ga_get_i(C.E_COUNT)
                if c < 20 then ga_set_i(C.E_COUNT, c + 1) end
            end
            ex = ex + ew + 0.015
            if C.btn_rect2(cursor, ex, sy, ew, sh) then
                local d = ga_get_i(C.E_DIST)
                if d > 1 then ga_set_i(C.E_DIST, d - 1) end
            end
            ex = ex + ew + 0.035
            if C.btn_rect2(cursor, ex, sy, ew, sh) then
                local d = ga_get_i(C.E_DIST)
                if d < C.DIST_MAX then ga_set_i(C.E_DIST, d + 1) end
            end
            ex = ex + ew + 0.015
            local tw = 0.065
            if C.btn_rect2(cursor, ex, sy, tw, sh) then ga_toggle_b(C.E_FREEZE) end
            ex = ex + tw + 0.015
            if C.btn_rect2(cursor, ex, sy, ew, sh) then
                local t = ga_get_i(C.E_TTL)
                if t > 0 then ga_set_i(C.E_TTL, t - 10) end
            end
            ex = ex + ew + 0.035
            if C.btn_rect2(cursor, ex, sy, ew, sh) then ga_set_i_by_delta(C.E_TTL, 10) end

        elseif S.cur_tab == C.TAB_INTERACT and C.tp.sub ~= nil then
            local b = C.tp.back
            if C.btn_rect(cursor, b.x, b.y, b.w, b.h) then C.tp.set(wid, nil) end

        elseif S.cur_tab == C.TAB_INTERACT then
            local raw = strip_target()
            if raw ~= nil and C.AMOUNT_BENTS[raw] then amount_strip_click(raw, cursor) end
            if raw ~= nil and C.PARAM_BENTS[raw] then param_strip_click(raw, cursor) end

        elseif S.cur_tab == C.TAB_DECOR then
            local clicked = nil
            decor_strip_layout(function(id, x, y, w, h)
                if clicked == nil and id ~= "d_val" and C.btn_rect(cursor, x, y, w, h) then clicked = id end
            end)
            if clicked and decor_strip_click(clicked) then
                ga_play_sound("menu_select")
            end

        elseif S.cur_tab == C.TAB_TELEPORT then
            local tx = 0.025
            local tw = 0.12
            if C.btn_rect2(cursor, tx, sy, tw, sh) then
                local ok, err = game_base_wp_system.teleport_home()
                ga_hud_msg("Teleporting home...", 2.0)
                ga_window_pop()
            end
            tx = tx + tw + 0.01
            if C.btn_rect2(cursor, tx, sy, tw + 0.02, sh) then
                local level = ga_get_viewer_level()
                local off   = ga_get_viewer_offset()
                local bp    = std.lp_to_bp(off)
                ga_bent_add(level, bp, "bent_base_waypoint", 60.0 * 60.0 * 24.0 * 365.0)
                ga_hud_msg("Placed waypoint marker at your position", 2.0)
            end
        end
    end

end

function C.render_control_strip_blocks(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    local sy = 0.095
    local sh = 0.035

    ga_win_quad_color(wid, 0.02, sy - 0.003, 0.98, sy + sh + 0.003, std.vec(0.06, 0.06, 0.10))

    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, 0.025, sy + sh + 0.008, "VIEW")
    ga_win_set_front_color_default(wid)
    local vx = 0.025
    local vw = 0.065
    C.small_btn(wid, cursor, vx, sy, vw, sh, "ALL", S.view_mode == "ALL")
    vx = vx + vw + 0.005
    C.small_btn(wid, cursor, vx, sy, vw, sh, "* FAV", S.view_mode == "FAV")
    vx = vx + vw + 0.005
    C.small_btn(wid, cursor, vx, sy, vw + 0.01, sh, "RECENT", S.view_mode == "RECENT")

    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, 0.33, sy + sh + 0.008, "SORT")
    ga_win_set_front_color_default(wid)
    local sx = 0.33
    local sw = 0.065
    C.small_btn(wid, cursor, sx, sy, sw, sh, "A-Z", S.sort_mode == "NAME")
    sx = sx + sw + 0.005
    C.small_btn(wid, cursor, sx, sy, sw + 0.02, sh, "CATEGORY", S.sort_mode == "CATEGORY")

    local cur_shape = C.gets(C.BR_SHAPE, "single")
    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, 0.52, sy + sh + 0.008, "BRUSH")
    ga_win_set_front_color_default(wid)
    local bx = 0.52
    local bw = 0.060
    C.small_btn(wid, cursor, bx, sy, bw, sh, "SINGLE", cur_shape == "single")
    bx = bx + bw + 0.005
    C.small_btn(wid, cursor, bx, sy, bw, sh, "CUBE", cur_shape == "cube")
    bx = bx + bw + 0.005
    C.small_btn(wid, cursor, bx, sy, bw + 0.005, sh, "SPHERE", cur_shape == "sphere")

    local cur_size = ga_get_i(C.BR_SIZE)
    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, 0.77, sy + sh + 0.008, "SIZE")
    ga_win_set_front_color_default(wid)
    local bsx = 0.77
    local bsw = 0.035
    C.small_btn(wid, cursor, bsx, sy, bsw, sh, "-", false)
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(1, 1, 1))
    ga_win_txt(wid, bsx + bsw + 0.010, sy + sh * 0.5 - 0.008, tostring(cur_size))
    ga_win_set_front_color_default(wid)
    bsx = bsx + bsw + 0.035
    C.small_btn(wid, cursor, bsx, sy, bsw, sh, "+", false)

    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.4, 0.4, 0.4))
    ga_win_txt(wid, 0.88, sy + 0.010, "R-click = fav")
    ga_win_set_front_color_default(wid)
end

function C.render_control_strip_entities(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    local sy = 0.095
    local sh = 0.035

    ga_win_quad_color(wid, 0.02, sy - 0.003, 0.98, sy + sh + 0.003, std.vec(0.06, 0.06, 0.10))

    local ew = 0.030

    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, 0.025, sy + sh + 0.008, "COUNT")
    ga_win_set_front_color_default(wid)
    local ex = 0.025
    C.small_btn(wid, cursor, ex, sy, ew, sh, "-", false)
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(1, 1, 1))
    ga_win_txt(wid, ex + ew + 0.008, sy + sh * 0.5 - 0.008, tostring(ga_get_i(C.E_COUNT)))
    ga_win_set_front_color_default(wid)
    ex = ex + ew + 0.035
    C.small_btn(wid, cursor, ex, sy, ew, sh, "+", false)
    ex = ex + ew + 0.015

    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, ex, sy + sh + 0.008, "DIST")
    ga_win_set_front_color_default(wid)
    C.small_btn(wid, cursor, ex, sy, ew, sh, "-", false)
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(1, 1, 1))
    ga_win_txt(wid, ex + ew + 0.008, sy + sh * 0.5 - 0.008, tostring(ga_get_i(C.E_DIST)))
    ga_win_set_front_color_default(wid)
    ex = ex + ew + 0.035
    C.small_btn(wid, cursor, ex, sy, ew, sh, "+", false)
    ex = ex + ew + 0.015

    local tw = 0.065
    local freeze = ga_get_b(C.E_FREEZE)
    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, ex, sy + sh + 0.008, "")
    ga_win_set_front_color_default(wid)
    C.small_btn(wid, cursor, ex, sy, tw, sh, "FREEZE", freeze)
    ex = ex + tw + 0.005

    ex = ex + 0.010

    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, ex, sy + sh + 0.008, "TTL(s)")
    ga_win_set_front_color_default(wid)
    C.small_btn(wid, cursor, ex, sy, ew, sh, "-", false)
    local ttl_val = ga_get_i(C.E_TTL)
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(1, 1, 1))
    ga_win_txt(wid, ex + ew + 0.008, sy + sh * 0.5 - 0.008, ttl_val == 0 and "INF" or tostring(ttl_val))
    ga_win_set_front_color_default(wid)
    ex = ex + ew + 0.035
    C.small_btn(wid, cursor, ex, sy, ew, sh, "+", false)
end

-- INTERACT settings strip for the selected hotbar ent: its amount (XP /
-- seconds / ammo / price) and / or text param (combo / area / var / upgrade)
function C.render_control_strip_interact(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    local sy, sh = 0.095, 0.035
    local y_lab, y_leg = sy + sh + 0.008, sy + sh + 0.034     -- label row, legend row
    ga_win_quad_color(wid, 0.02, sy - 0.003, 0.98, sy + sh + 0.003, std.vec(0.06, 0.06, 0.10))

    local raw = strip_target()
    if raw == nil then
        ga_win_set_char_size(wid, 0.008, 0.016)
        ga_win_set_front_color(wid, std.vec(0.45, 0.45, 0.55))
        ga_win_txt(wid, 0.03, sy + sh * 0.5 - 0.007,
            "SETTINGS: pick XP, a powerup, a key, huge ammo, a toll, a green key / door or a door unlock")
        ga_win_set_front_color_default(wid)
        return
    end

    local function label(x, y, txt, col)
        ga_win_set_char_size(wid, 0.007, 0.014)
        ga_win_set_front_color(wid, col or std.vec(0.6, 0.6, 0.6))
        ga_win_txt(wid, x, y, txt)
        ga_win_set_front_color_default(wid)
    end

    -- amount: - value + presets
    local a = C.AMOUNT_BENTS[raw]
    if a ~= nil then
        local v = C.amount_get(raw)
        label(0.025, y_lab, "AMOUNT (" .. a.unit .. (a.neg and ", - = negative" or "") .. ")   - / + "
            .. C.fmt_int(amount_step(a)))
        label(0.025, y_leg, "- / + step: Ctrl 10 | Shift 1K | Ctrl+Shift 10K", std.vec(0.45, 0.45, 0.55))
        amount_strip_layout(raw, function(id, x, y, w, h, lbl, n)
            if id == "value" then
                ga_win_quad_color(wid, x, y, x + w, y + h, std.vec(0.03, 0.03, 0.06))
                C.num_field(wid, "amt:" .. raw, x + 0.008, y + h * 0.5 - 0.008, 0.010, 0.020, v,
                    function(nv) C.amount_set(raw, nv) end,
                    { max_w = w - 0.016, col = std.vec(1.0, 0.9, 0.3), neg = a.neg })
            else
                C.small_btn(wid, cursor, x, y, w, h, lbl, n ~= nil and n == v)
            end
        end)
    end

    -- text param: a text field, or < value > for a fixed list
    local p = C.PARAM_BENTS[raw]
    if p ~= nil then
        local px = param_x0(raw)
        local s = C.param_get(raw)
        label(px, y_lab, p.label)
        param_strip_layout(raw, px, function(id, x, y, w, h, lbl)
            if id == "ptext" then
                ga_win_quad_color(wid, x, y, x + w, y + h, std.vec(0.03, 0.03, 0.06))
                C.num_field(wid, "txt:" .. raw, x + 0.008, y + h * 0.5 - 0.008, 0.009, 0.018, s,
                    function(ns) C.param_set(raw, ns) end,
                    { text = true, placeholder = "(none) - click to type", min_w = w - 0.02,
                      max_w = w - 0.016, col = std.vec(1.0, 0.9, 0.3) })
            elseif id == "pval" then
                ga_win_quad_color(wid, x, y, x + w, y + h, std.vec(0.03, 0.03, 0.06))
                ga_win_set_char_size(wid, 0.009, 0.018)
                ga_win_set_front_color(wid, std.vec(1.0, 0.9, 0.3))
                ga_win_txt(wid, x + 0.008, y + h * 0.5 - 0.008, C.fit(s, math.floor((w - 0.016) / 0.009)))
                ga_win_set_front_color_default(wid)
            else
                C.small_btn(wid, cursor, x, y, w, h, lbl, false)
            end
        end)
    end

    -- which ent this is for (legend row, right)
    local name = (C.INTERACT_LABEL[raw] or C.clean_bent_name(raw)) .. "  -  hotbar slot " .. C.cur_slot()
    ga_win_set_char_size(wid, 0.008, 0.016)
    ga_win_set_front_color(wid, std.vec(1.0, 0.9, 0.3))
    ga_win_txt(wid, 0.97 - #name * 0.008, y_leg, name)
    ga_win_set_front_color_default(wid)
end

function C.render_pick_hint(wid, line)
    ga_win_set_char_size(wid, 0.0075, 0.015)
    ga_win_set_front_color(wid, std.vec(0.55, 0.55, 0.62))
    ga_win_txt_center(wid, 0.212, line)
    ga_win_set_front_color_default(wid)
end

-- INTERACT -> Trophies page: BACK button + notes
function C.render_trophy_strip(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    local b = C.tp.back
    ga_win_quad_color(wid, 0.02, 0.092, 0.98, 0.133, std.vec(0.06, 0.06, 0.10))
    C.small_btn(wid, cursor, b.x, b.y, b.w, b.h, "< BACK TO INTERACT", false)
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt(wid, b.x + b.w + 0.03, b.y + 0.008, "TROPHIES - click one to put it in the hotbar")
    ga_win_set_front_color_default(wid)
    C.render_pick_hint(wid, "In world: L-click places it in the white cell, R-click removes the red one, Alt+wheel = distance, Ctrl = id.")
    ga_win_set_char_size(wid, 0.0075, 0.015)
    ga_win_set_front_color(wid, std.vec(0.85, 0.65, 0.35))
    ga_win_txt_center(wid, 0.188, "Trophies are real: touching one collects it (gold/health bonus + its Steam achievement).")
    ga_win_set_front_color_default(wid)
end

function C.render_control_strip_decor(wid)
    local cursor = ga_win_get_cursor_pos(wid)
    ga_win_quad_color(wid, 0.02, 0.092, 0.98, 0.133, std.vec(0.06, 0.06, 0.10))
    decor_strip_layout(function(id, x, y, w, h, label, active, group)
        if group then
            ga_win_set_char_size(wid, 0.007, 0.014)
            ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
            ga_win_txt(wid, x, y + h + 0.008, group)
            ga_win_set_front_color_default(wid)
        end
        if id == "d_val" then
            ga_win_set_char_size(wid, 0.010, 0.020)
            ga_win_set_front_color(wid, std.vec(1, 1, 1))
            ga_win_txt(wid, x + w * 0.5 - 0.005 * #label, y + h * 0.5 - 0.008, label)
            ga_win_set_front_color_default(wid)
        else
            C.small_btn(wid, cursor, x, y, w, h, label, active)
        end
    end)

    C.render_pick_hint(wid, "Click = put in hotbar. In world: L-click place, R-click remove, Alt+wheel = distance. Aim at a wall to hang pictures.")
    ga_win_set_front_color_default(wid)
end

function C.render_teleport_tab(wid)
    C.render_grid_tab(wid, "teleport")

    local cursor = ga_win_get_cursor_pos(wid)
    local sy = 0.095
    local sh = 0.035

    ga_win_quad_color(wid, 0.02, sy - 0.003, 0.98, sy + sh + 0.003, std.vec(0.06, 0.06, 0.10))

    local tx = 0.025
    local tw = 0.12
    C.small_btn(wid, cursor, tx, sy, tw, sh, "HOME (F7)", false)
    tx = tx + tw + 0.01
    C.small_btn(wid, cursor, tx, sy, tw + 0.02, sh, "PLACE WP HERE", false)

    tx = tx + tw + 0.04
    ga_win_set_char_size(wid, 0.008, 0.016)
    ga_win_set_front_color(wid, std.vec(0.5, 0.5, 0.5))
    ga_win_txt(wid, tx, sy + 0.010, "Click a waypoint to warp | F6 = warp by search")
    ga_win_set_front_color_default(wid)
end

function C.render_grid_tab(wid, mode)
    ga_win_set_char_size(wid, 0.009, 0.018)
    ga_win_set_front_color(wid, std.vec(0.7, 0.7, 0.3))
    ga_win_txt_center(wid, 0.810, "Page " .. (S.page + 1) .. "/" .. C.num_pages() .. "   (" .. #S.items .. " entries)")
    ga_win_set_front_color_default(wid)

    local gx0 = C.X0 - 0.006
    local gx1 = C.X0 + S.COLS * S.CW + 0.001
    local gy_top = C.Y0 + 0.010
    local gy_bot = C.Y0 - (S.ROWS - 1) * S.CH - (S.CH - C.GAPY) - 0.006
    ga_win_quad_color(wid, gx0 - 0.003, gy_bot - 0.003, gx1 + 0.003, gy_top + 0.003, std.vec(0.15, 0.15, 0.22))
    ga_win_quad_color(wid, gx0, gy_bot, gx1, gy_top, std.vec(0.08, 0.08, 0.12))

    if #S.items == 0 then
        local msg = "No matches"
        if mode == "block" and S.view_mode == "FAV" then
            msg = "No favorites yet - right-click a block to add one"
        elseif mode == "block" and S.view_mode == "RECENT" then
            msg = "No recent blocks yet - pick one to start building"
        elseif mode == "teleport" then
            msg = "No waypoints found"
        end
        ga_win_set_char_size(wid, C.fix_charw(0.010), 0.020)
        ga_win_set_front_color(wid, std.vec(0.45, 0.45, 0.55))
        ga_win_txt_center(wid, (gy_top + gy_bot) * 0.5, msg)
        ga_win_set_front_color_default(wid)
    end

    local cursor = ga_win_get_cursor_pos(wid)
    local hov_gi, hov_li = C.hovered_index(cursor)
    local sel_kind, sel_raw = C.cur_entry()
    local GRID_KIND = { block = "block", entity = "ment", interact = "bent" }

    for i = 0, S.PER_PAGE - 1 do
        local gi = S.page * S.PER_PAGE + i + 1
        local it = S.items[gi]
        if it ~= nil then
            local minx, miny, maxx, maxy = C.cell_rect(i)
            local want_kind = it.kind or GRID_KIND[mode]   -- decor / trophy page items carry their kind
            local is_sel = (want_kind ~= nil and sel_kind == want_kind and it.raw == sel_raw)
                        or (mode == "weapon" and it.raw == S.sel_weapon)
            local is_hov = (gi == hov_gi)

            local tex = ""
            if     mode == "block"    then tex = C.block_tex(it.raw)
            elseif mode == "entity"   then tex = C.ent_tex(it.raw)
            elseif mode == "interact" then tex = C.valid_tex(it.tex)
            elseif mode == "decor"    then tex = C.valid_tex(it.tex)
            end
            if tex ~= "" then
                ga_win_quad(wid, minx, miny, maxx, maxy, tex)
            elseif mode == "weapon" then
                ga_win_quad(wid, minx, miny, maxx, maxy, "ammo_gun"..(gi-1))
            else
                local c = it.col
                if is_hov then c = std.vec(0.85, 0.85, 0.95) end
                if is_sel then c = std.vec(1.0, 0.9, 0.2) end
                ga_win_quad_color(wid, minx, miny, maxx, maxy, c)
            end

            if is_hov or is_sel then
                local fcol = is_sel and std.vec(1.0, 0.9, 0.2) or std.vec(1.0, 1.0, 1.0)
                local t = 0.004
                ga_win_quad_color(wid, minx, maxy - t, maxx, maxy, fcol)
                ga_win_quad_color(wid, minx, miny, maxx, miny + t, fcol)
                ga_win_quad_color(wid, minx, miny, minx + C.fix_padding(t), maxy, fcol)
                ga_win_quad_color(wid, maxx - C.fix_padding(t), miny, maxx, maxy, fcol)
            end

            --f mode == "weapon" then
                --ga_win_set_char_size(wid, 0.012, 0.024)
                --ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
                --ga_win_txt(wid, minx + (maxx - minx) * 0.5 - 0.004, miny + (maxy - miny) * 0.5 - 0.012, tostring(it.raw))
                --ga_win_set_front_color_default(wid)
            --[[else]]if mode == "teleport" then
                local max_chars = math.max(1, math.floor((maxx - minx) / 0.008))
                ga_win_set_char_size(wid, 0.006, 0.012)
                ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
                ga_win_txt(wid, minx + 0.004, miny + (maxy - miny) * 0.5 - 0.005, C.fit(it.label, max_chars))
                ga_win_set_front_color_default(wid)
            end
        end
    end

    if hov_gi >= 1 then
        local it = S.items[hov_gi]
        -- entities / interact: display name, hold Ctrl for the id
        -- (ment_monster_ogre, bent_buy_station, trophy api name / st_*)
        local raw_name = S.ctrl_down == true and (mode == "entity"
                      or (mode == "interact" and it.raw ~= C.tp.entry))
        local shown = raw_name and it.raw or it.label
        if mode == "interact" and it.kind == nil and not raw_name then
            shown = shown .. C.bent_suffix(it.raw)          -- "Experience (1,000 XP)"
        end
        local cw_t = 0.0092
        ga_win_set_char_size(wid, cw_t, 0.020)
        local tw = 0.0108 * #shown + 0.014
        local tx = cursor.x + 0.015
        local ty = cursor.y + 0.015
        if tx + tw > 0.98 then tx = 0.98 - tw end
        if ty + 0.03 > 0.95 then ty = cursor.y - 0.04 end
        ga_win_quad_color(wid, tx - 0.005, ty - 0.005, tx + tw + 0.005, ty + 0.032, std.vec(0.12, 0.12, 0.18))
        ga_win_quad_color(wid, tx - 0.003, ty - 0.003, tx + tw + 0.003, ty + 0.030, std.vec(0.02, 0.02, 0.02))
        ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
        ga_win_txt(wid, tx + 0.003, ty + 0.005, shown)
        ga_win_set_front_color_default(wid)
    end
end

-- not a real window: only here so the window Lua state loads it
function p.__start(wid) end
function p.__end(wid) end
function p.__on_start(wid) end
function p.__on_end(wid) end
function p.__render(wid) end
function p.__process_input(wid) end
