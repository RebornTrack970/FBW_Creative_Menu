local aspect = 1
local std_aspect = 16/9

-- important: width of ga_win_txt = len_txt*char_width

local SEL_VAR  = "creative.selected_block"
local MODE_VAR = "creative.build_mode"

local TAB_BLOCKS   = 1
local TAB_WEAPONS  = 2
local TAB_ITEMS    = 3
local TAB_BUFFS    = 4
local TAB_ENTITIES = 5
local TAB_INTERACT = 6
local TAB_TELEPORT = 7
local TAB_COUNT    = 7

local FAV_VAR   = "creative.favorites"
local REC_VAR   = "creative.recents"
local WP_VAR    = "creative.wp_search"
local BR_SHAPE  = "creative.brush_shape"
local BR_SIZE   = "creative.brush_size"
local E_COUNT, E_DIST, E_FREEZE, E_ALLY, E_TTL =
    "creative.ent_count", "creative.ent_dist", "creative.ent_freeze",
    "creative.ent_ally", "creative.ent_ttl"

local X0, Y0     = 0.025, 0.78
local GRID_W     = 0.95
local GRID_H     = 0.58
local TILE_Y     = 0.082
local GAPX, GAPY = 0.004, 0.006
local COLS, ROWS = 16, 8
local CW, CH     = TILE_Y, TILE_Y + GAPY
local PER_PAGE   = COLS * ROWS

-- makes the text size look the same as std_aspect for all aspect ratios
local function fix_charw(charw)
    return charw/aspect*std_aspect
end
local function fix_padding(padding)
    return padding/aspect
end

local function compute_grid()
    local tile_w = TILE_Y / aspect
    CW = tile_w + GAPX
    CH = TILE_Y + GAPY
    COLS = math.max(1, math.floor((GRID_W + GAPX) / CW))
    ROWS = math.max(1, math.floor((GRID_H + GAPY) / CH))
    PER_PAGE = COLS * ROWS
end

local cur_tab      = TAB_BLOCKS
local items        = {}
local page         = 0
local sel_weapon   = 0
local view_mode    = "ALL"
local sort_mode    = "NAME"
local last_tab     = -1
local last_search  = nil
local inited       = false
local use_3d_mesh  = nil
local tex_set      = nil
local tex_norm     = nil
local tex_cache    = {}

local INTERACT_LABEL = {
    bent_buy_station              = "Shop (Buy Station)",
    bent_black_market             = "Black Market",
    bent_sell_station_common      = "Sell (Common)",
    bent_sell_station_scarce      = "Sell (Scarce)",
    bent_sell_station_rare        = "Sell (Rare)",
    bent_upgrade_station          = "Upgrade Station",
    bent_upgrade_station_max_ammo = "Upgrade Max Ammo",
    bent_upgrade_telekinesis      = "Upgrade Telekinesis",
    bent_sleep                    = "Sleep",
    bent_sleep_hour               = "Sleep (1 Hour)",
    bent_pay_toll                 = "Pay Toll",
    bent_bookmark                 = "Bookmark / Waypoint",
    bent_cheap_common_markers     = "Cheap Markers",
    bent_buy_blue_key             = "Buy Blue Key",
    bent_key_yellow               = "Yellow Key",
    bent_key_green                = "Green Key",
    bent_key_laser_genesis        = "Laser Genesis Key",
    bent_key_dans_house           = "Dan's House Key",
    bent_credits                  = "Credits",
    bent_arcade_enter             = "Arcade Enter",
}

local function clean_name(raw)
    if string.sub(raw, 1, 4) == "XAR_" then return string.sub(raw, 5) end
    return raw
end

local function clean_ent_name(raw)
    local s = raw
    if string.sub(s, 1, 13) == "ment_monster_" then s = string.sub(s, 14) end
    if string.sub(s, 1, 5) == "ment_" then s = string.sub(s, 6) end
    s = string.gsub(s, "_", " ")
    s = string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
    return s
end

local function category_of(clean)
    return string.match(clean, "^[^_]+") or clean
end

local function cat_color(cat)
    local h = 0
    for i = 1, #cat do h = (h * 31 + string.byte(cat, i)) % 100003 end
    local r = 0.25 + (h % 55) / 100
    local g = 0.25 + (math.floor(h / 7) % 55) / 100
    local b = 0.25 + (math.floor(h / 53) % 55) / 100
    return std.vec(r, g, b)
end

local function fit(label, n)
    if #label > n then return string.sub(label, 1, n - 1) .. "." end
    return label
end

local DROP_TOKENS = { solid = true, boring = true, block = true, xar = true }

local TEX_FALLBACK_PREFIXES = {
    "Monster", "block_", "ent_", "bent_", "key_", "buy_", "sell_", "upgrade_",
    "gold_", "health_", "armor_", "ammo_", "sleep", "pay_", "black_", "arcade_",
    "genesis_", "cheap_", "invun", "damage_", "xp", "shield", "spice", "trophy",
    "icarus", "secret_", "marker_", "WhiteBox", "YellowBox", "Drop", "icon_", "pic_",
}

local function norm_key(s)
    return (string.gsub(string.lower(s), "[^%w]", ""))
end

local function ensure_tex_set()
    if tex_set ~= nil then return end
    tex_set, tex_norm = {}, {}
    local function add(nm)
        if type(nm) == "string" and nm ~= "" and not tex_set[nm] then
            tex_set[nm] = true
            local k = norm_key(nm)
            if tex_norm[k] == nil then tex_norm[k] = nm end
        end
    end
    local function pull(pre)
        local n = 0
        local arr = ga_get_tex_names_with_prefix(pre)
        if arr then
            for _, v in ipairs(arr) do
                local nm = v
                if type(v) == "table" then nm = v.name end
                add(nm); n = n + 1
            end
        end
        return n
    end
    if pull("") == 0 then
        for _, pre in ipairs(TEX_FALLBACK_PREFIXES) do pull(pre) end
    end
end

local function ntex(name)
    if name == nil or name == "" then return nil end
    ensure_tex_set()
    return tex_norm[norm_key(name)]
end

local function fuzzy_tex(base, prefix, drop)
    local toks = {}
    for t in string.gmatch(base, "[^_]+") do
        if not drop[t] then toks[#toks + 1] = t end
    end
    for start = 1, #toks do
        local cand = ntex(prefix .. table.concat(toks, "_", start))
        if cand then return cand end
    end
    for stop = #toks, 1, -1 do
        local cand = ntex(prefix .. table.concat(toks, "_", 1, stop))
        if cand then return cand end
    end
    return ""
end

local function block_tex(raw)
    local cached = tex_cache[raw]
    if cached ~= nil then return cached end
    ensure_tex_set()
    local found
    if raw:sub(1,6) == "block_" then
        -- grab the texture from the module like a normal person
        if _G[raw] and _G[raw].__get_tex then
            found = _G[raw].__get_tex() -- returns "" if no texture.
        elseif _G[raw] and _G[raw].__get_bt_to_copy then -- new 1.02.00 feature
            found = block_tex(_G[raw].__get_bt_to_copy())
        end
    else
        found = fuzzy_tex(string.lower(clean_name(raw)), "block_", DROP_TOKENS)
    end
    -- TODO error handling here
    found = found or ""
    tex_cache[raw] = found
    return found
end

local ENT_FILLER = { ment = true, monster = true, guard = true, general = true, the = true }
local ENT_TEX_OVERRIDE = { ment_general_drop_box = "Drop" }
local ent_tex_cache = {}

local function ent_tex(raw)
    local cached = ent_tex_cache[raw]
    if cached ~= nil then return cached end
    ensure_tex_set()
    local found = ""
    local ov = ENT_TEX_OVERRIDE[raw]
    if ov and tex_set[ov] then found = ov end
    if found == "" then
        local s = raw
        if     string.sub(s, 1, 13) == "ment_monster_" then s = string.sub(s, 14)
        elseif string.sub(s, 1, 5)  == "ment_"         then s = string.sub(s, 6) end
        local toks = {}
        for t in string.gmatch(s, "[^_]+") do
            if not ENT_FILLER[t] then toks[#toks + 1] = t end
        end
        for stop = #toks, 1, -1 do
            local joined = table.concat(toks, "", 1, stop)
            local m = ntex("monster" .. joined) or ntex(joined)
            if m then found = m; break end
        end
    end
    ent_tex_cache[raw] = found
    return found
end

local function valid_tex(name)
    return ntex(name) or ""
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

local function clean_bent_name(raw)
    local s = raw
    if string.sub(s, 1, 5) == "bent_" then s = string.sub(s, 6) end
    s = string.gsub(s, "_", " ")
    s = string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
    return s
end

local bent_tex_cache = {}

--local mesh_table = nil
local function set(t) local o = {} for i,v in ipairs(t) do o[v] = true end return o end
local invalid_meshes = set{"bent_ammo_gun_3_huge","bent_genesis_marker_long","bent_genesis_marker_short"}
local function mesh_exists(mesh)
    --if not mesh_table then

    --end
    if invalid_meshes[mesh] then return false end
    return true
end

local function bent_tex(raw)
    local cached = bent_tex_cache[raw]
    if cached ~= nil then return cached end
    ensure_tex_set()
    local found = ""
    if _G[raw] then
        -- grab the texture and mesh like a normal person
        local mesh = mesh_exists(raw) and raw or "" -- fbw uses mesh named the same as the bent implicitly
        if _G[raw].__get_mesh then mesh = _G[raw].__get_mesh() end
        if _G[raw].__on_render then mesh = "" end
        if mesh ~= "" then found = ga_mesh_get_tex(mesh) end
    end
    if found == "" then
        local stripped = raw
        if string.sub(raw, 1, 5) == "bent_" then stripped = string.sub(raw, 6) end
        local cands = {
            raw,
            stripped,
            (string.gsub(stripped, "_once", "")),
            "ent_" .. stripped,
        }
        for _, cd in ipairs(cands) do
            local m = (tex_set[cd] and cd) or ntex(cd)
            if m then found = m; break end
        end
    end
    bent_tex_cache[raw] = found
    return found
end

local function set_var(cmd_str)
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

local function btn_rect(cursor, x, y, w, h)
    return cursor.x >= x and cursor.x <= x + w and cursor.y >= y and cursor.y <= y + h
end
local function btn_rect2(cursor, x, y, w, h)
    if btn_rect(cursor, x, y, w, h) then
        ga_play_sound("menu_select")
        return true
    end
    return false
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

local function is_fav(raw) return list_has(csv_list(FAV_VAR), raw) end
local function fav_toggle(raw)
    local t = csv_list(FAV_VAR)
    for i, x in ipairs(t) do
        if x == raw then table.remove(t, i); csv_save(FAV_VAR, t); return false end
    end
    t[#t + 1] = raw; csv_save(FAV_VAR, t); return true
end
local function add_recent(raw)
    local t = csv_list(REC_VAR)
    for i, x in ipairs(t) do if x == raw then table.remove(t, i); break end end
    table.insert(t, 1, raw)
    while #t > 24 do t[#t] = nil end
    csv_save(REC_VAR, t)
end

local default_padding = 0.0025
local function small_btn(wid, cursor, x, y, w, h, label, active)
    local hov = btn_rect(cursor, x, y, w, h)
    local col = active and std.vec(0.50, 0.45, 0.18)
             or (hov and std.vec(0.34, 0.34, 0.50) or std.vec(0.18, 0.20, 0.28))
    local padding = default_padding
    ga_win_quad_color(wid, x - fix_padding(padding), y - padding, x + w + fix_padding(padding), y + h + padding, std.vec(0.40, 0.40, 0.55))
    ga_win_quad_color(wid, x, y, x + w, y + h, col)
    ga_win_set_char_size(wid, 0.009, 0.018)
    ga_win_set_front_color(wid, std.vec(1, 1, 1))
    ga_win_txt(wid, x + 0.006, y + h * 0.5 - 0.008, label)
    ga_win_set_front_color_default(wid)
    return hov
end

local function gets(var, d) local v = ga_get_s(var); if type(v) == "string" and v ~= "" then return v end return d end

local function rebuild(wid)
    items = {}
    local search = ""
    local search_val = ga_win_widget_text_input_get_text(wid)
    if search_val then search = string.upper(search_val) end

    if cur_tab == TAB_BLOCKS then
        local fav_set, rec_list
        if view_mode == "FAV" then
            fav_set = {}
            for _, v in ipairs(csv_list(FAV_VAR)) do fav_set[v] = true end
        elseif view_mode == "RECENT" then
            rec_list = csv_list(REC_VAR)
        end

        local names = enum_names(ga_get_block_names_with_prefix, "")
        if #names == 0 then names = enum_names(ga_get_block_names_with_prefix, "XAR_") end

        if view_mode == "RECENT" and rec_list then
            for _, nm in ipairs(rec_list) do
                local bad = block_wiki_bad_blocks[nm]
                local match = (search == "") or string.find(string.upper(nm), search, 1, true)
                if (not bad) and match then
                    local c = clean_name(nm)
                    local cat = category_of(c)
                    items[#items + 1] = { raw = nm, label = c, cat = cat, col = cat_color(cat) }
                end
            end
        else
            for _, nm in ipairs(names) do
                local bad = block_wiki_bad_blocks[nm]
                local match = (search == "") or string.find(string.upper(nm), search, 1, true)
                local mode_ok = true
                if fav_set then mode_ok = (fav_set[nm] == true) end
                if (not bad) and match and mode_ok then
                    local c = clean_name(nm)
                    local cat = category_of(c)
                    items[#items + 1] = { raw = nm, label = c, cat = cat, col = cat_color(cat) }
                end
            end
        end

        if sort_mode == "CATEGORY" then
            table.sort(items, function(a, b)
                if a.cat ~= b.cat then return a.cat < b.cat end
                return a.label < b.label
            end)
        end

    elseif cur_tab == TAB_WEAPONS then
        for n = 0, 9 do
            local nm = "Weapon " .. n
            if game_wep_modes and game_wep_modes.get_wep_name then
                nm = game_wep_modes.get_wep_name(n)
            end
            items[#items + 1] = { raw = n, label = nm, cat = "WEP", col = std.vec(0.35, 0.25, 0.15) }
        end

    elseif cur_tab == TAB_ITEMS then
        items = {}

    elseif cur_tab == TAB_BUFFS then
        items = {}

    elseif cur_tab == TAB_ENTITIES then
        local names = enum_names(ga_get_ment_names_with_prefix, "")
        if #names == 0 then names = enum_names(ga_get_ment_names_with_prefix, "ment_") end
        for _, ent in ipairs(names) do
            local match = (search == "") or string.find(string.upper(ent), search, 1, true)
            if match then
                items[#items + 1] = { raw = ent, label = clean_ent_name(ent), cat = "ENT", col = std.vec(0.30, 0.20, 0.35) }
            end
        end

    elseif cur_tab == TAB_INTERACT then
        local names = enum_names(ga_get_bent_names_with_prefix, "")
        if #names == 0 then names = enum_names(ga_get_bent_names_with_prefix, "bent_") end
        for _, raw in ipairs(names) do
            local label = INTERACT_LABEL[raw] or clean_bent_name(raw)
            local hay   = string.upper(label .. " " .. raw)
            local match = (search == "") or string.find(hay, search, 1, true)
            if match then
                items[#items + 1] = {
                    raw = raw, label = label, cat = "INT",
                    col = std.vec(0.18, 0.30, 0.30),
                    tex = bent_tex(raw),
                }
            end
        end

    elseif cur_tab == TAB_TELEPORT then
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
                        items[#items + 1] = {
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
    page = 0
end

local function num_pages()
    if #items == 0 then return 1 end
    return math.floor((#items - 1) / PER_PAGE) + 1
end

local function cell_rect(i)
    local col = i % COLS
    local row = math.floor(i / COLS)
    local minx = X0 + col * CW
    local maxy = Y0 - row * CH
    return minx, maxy - (CH - GAPY), minx + (CW - GAPX), maxy
end

local function hovered_index(cursor)
    for i = 0, PER_PAGE - 1 do
        local minx, miny, maxx, maxy = cell_rect(i)
        if cursor.x >= minx and cursor.x <= maxx and cursor.y >= miny and cursor.y <= maxy then
            local gi = page * PER_PAGE + i + 1
            if gi <= #items then return gi, i end
        end
    end
    return -1, -1
end

local function set_build_mode(on)
    ga_set_b(MODE_VAR, on)
    if on then
        ga_command('bind MOUSE1.downup tocommand "creative_break"')
        ga_command('bind MOUSE2.downup tocommand "creative_place"')
        ga_hud_msg("Build: ON  (L break / R place)", 2.0)
    else
        ga_command('bind MOUSE1.downup tocommands "use_equipped primary start" "use_equipped primary stop"')
        ga_command('bind MOUSE2.downup tocommands "use_equipped secondary start" "use_equipped secondary stop"')
        ga_hud_msg("Build: OFF  (mouse = weapons)", 2.0)
    end
end

local function choose_block(gi)
    local it = items[gi]
    if it == nil then return end
    ga_set_s(SEL_VAR, it.raw)
    add_recent(it.raw)
    set_build_mode(true)
    ga_play_sound("menu_select")
    ga_window_pop()
end

local function choose_weapon(gi)
    local it = items[gi]
    if it == nil then return end
    local n = tonumber(it.raw)
    if n ~= nil then sel_weapon = n end
    ga_play_sound("menu_select")
end

local function choose_entity(gi)
    local it = items[gi]
    if it == nil then return end
    local count  = ga_get_i(E_COUNT)
    local dist   = ga_get_i(E_DIST)
    local ttl    = ga_get_i(E_TTL)
    if count < 1 then count = 1 end
    if count > 20 then count = 20 end
    if dist < 1 then dist = 1 end
    if dist > 50 then dist = 50 end

    local level = ga_get_viewer_level()
    local off   = ga_get_viewer_offset()
    local look  = ga_get_sys_v("game.player.camera.look")
    local spawned = 0
    for i = 1, count do
        local spread = 0
        if count > 1 then spread = (i - (count + 1) / 2) * 1.5 end
        local px = off.x + look.x * dist + (-look.z) * spread
        local py = off.y + look.y * dist
        local pz = off.z + look.z * dist + look.x * spread
        local pos = std.vec(px, py, pz)
        ga_ment_start(level, pos, it.raw)
        if ga_get_b(E_FREEZE) then ga_ment_init_set_b("__vel_disabled", true) end
        if ga_get_b(E_ALLY)   then ga_ment_init_set_i("__team_id_target", 1) end
        if ttl > 0 then ga_ment_init_set_f("__ttl", ttl * 1.0) end
        ga_ment_end()
        spawned = spawned + 1
    end
    ga_hud_msg("spawned " .. spawned .. "x " .. it.raw, 2.0)
    ga_play_sound("menu_select")
end

local function choose_interactable(gi)
    local it = items[gi]
    if it == nil then return end
    local level = ga_get_viewer_level()
    local off   = ga_get_viewer_offset()
    local look  = ga_get_sys_v("game.player.camera.look")
    local lp    = std.vec(off.x + look.x * 3.0, off.y + look.y * 3.0, off.z + look.z * 3.0)
    local bp    = std.lp_to_bp(lp)
    ga_bent_add(level, bp, it.raw, 60.0 * 60.0 * 24.0)
    ga_hud_msg("placed " .. it.raw, 2.0)
    ga_play_sound("menu_select")
end

local function choose_teleport(gi)
    local it = items[gi]
    if it == nil then return end
    local handle = tonumber(it.raw)
    if handle == nil then return end
    game_base_wp_system.teleport_target_only(handle)
    ga_hud_msg("warping to " .. it.label, 2.0)
    ga_play_sound("menu_select")
    ga_window_pop()
end

local ITEM_BUTTONS = {
    { section = "GOLD", var = "xar.player.gold.amount", buttons = {
        { label = "+1K",   delta = 1000 },
        { label = "+10K",  delta = 10000 },
        { label = "+100K", delta = 100000 },
        { label = "Set 0", value = 0 },
        { label = "Max",   value = 1000000 },
    }},
    { section = "HEALTH", var = "xar.player.health.amount", buttons = {
        { label = "+100",  delta = 100 },
        { label = "+1000", delta = 1000 },
        { label = "Set 1", value = 1 },
        { label = "Max",   value = 99999 },
    }},
    { section = "ARMOR", var = "xar.player.armor.amount", buttons = {
        { label = "+100",  delta = 100 },
        { label = "+1000", delta = 1000 },
        { label = "+10000", delta = 10000 },
        { label = "Set 0", value = 0 },
    }},
    { section = "SHIELD", var = "xar.player.shield.amount", buttons = {
        { label = "+100",  delta = 100 },
        { label = "+1000", delta = 1000 },
        { label = "+1000", delta = 10000 },
        { label = "Set 0", value = 0 },
    }},
    { section = "XP (total)", var = "xar.experience.total", buttons = {
        { label = "+1000 XP", delta = 1000 },
        { label = "+10000 XP", delta = 10000 },
    }},
}

local BUFF_BUTTONS = {
    { section = "KEYS", entries = {
        { label = "Yellow Key 30s",  cmd = "f xar.key_time.yellow 30" },
        { label = "Yellow Key 300s", cmd = "f xar.key_time.yellow 300" },
        { label = "Blue Key 30s",    cmd = "f xar.key_time.blue 30" },
        { label = "Blue Key 300s",   cmd = "f xar.key_time.blue 300" },
        { label = "Green Key 30s",   cmd = "f xar.key_time.green 30" },
        { label = "Green Key 300s",  cmd = "f xar.key_time.green 300" },
        { label = "Universe Key 30s",cmd = "f xar.key_time.universe 30" },
        { label = "Universe Key 300s",cmd = "f xar.key_time.universe 300" },
        { label = "Laser Genesis 30s",cmd = "f xar.key_time.laser_genesis 30" },
        { label = "Dan's House 30s", cmd = "f xar.key_time.dans_house 30" },
        { label = "ALL Keys 60s",    cmd = "f xar.key_time.yellow 60" },
    }},
    { section = "POWERUPS", entries = {
        { label = "5x Damage 30s",   cmd = "f xar.damage_5x_stacking_time 30" },
        { label = "5x Damage 120s",  cmd = "f xar.damage_5x_stacking_time 120" },
        { label = "5x Damage 600s",  cmd = "f xar.damage_5x_stacking_time 600" },
        { label = "Invulnerable 30s",cmd = "f xar.invun_stacking_time 30" },
        { label = "Invulnerable 120s",cmd = "f xar.invun_stacking_time 120" },
        { label = "Invulnerable 600s",cmd = "f xar.invun_stacking_time 600" },
        { label = "5x XP 30s",       cmd = "f xar.xp_5x_stacking_time 30" },
        { label = "5x XP 120s",      cmd = "f xar.xp_5x_stacking_time 120" },
        { label = "5x XP 600s",      cmd = "f xar.xp_5x_stacking_time 600" },
    }},
    { section = "CHEATS (toggle)", entries = {
        -- engine console toggles; do NOT ga_set_sys_b metagame.cheat.god (READ ONLY = native crash)
        { label = "Enable cheats",   raw = "cheat hodisclosetov;if $metagame.cheat.enabled void (cheat on)" },
        { label = "Disable cheats",   raw = "cheat off" },
        { label = "God Mode",   raw = "god" },
        { label = "Noclip/Fly", raw = "noclip" },
        { label = "ShrinkAny", raw = "shrinkany" },
    }},
}

local GUN_UPGRADE_SUFFIXES = {
    "ammo_level", "ammo_regen_level", "damage_level", "speed_level",
    "fire_period_level", "num_level", "radius_level", "freeze_time_level",
}

local function set_var_if_exists(var, value)
    if ga_exists(var) then ga_set_i(var, value) end
end

local function gun_prefix() return "xar.player.gun" .. sel_weapon .. "." end

local function set_sel_ammo(value)
    set_var_if_exists(gun_prefix() .. "ammo", value)
    ga_hud_msg("weapon " .. sel_weapon .. " ammo -> " .. value, 1.5)
end

local function set_sel_upgrades(value)
    for _, suf in ipairs(GUN_UPGRADE_SUFFIXES) do
        set_var_if_exists(gun_prefix() .. suf, value)
    end
    ga_hud_msg("weapon " .. sel_weapon .. (value > 0 and " upgrades -> " or " upgrades removed -> ") .. value, 1.5)
end

local function equip_sel()
    ga_set_i("xar.player.cur_wep", sel_weapon)
    set_build_mode(false)
    ga_hud_msg("equipped weapon " .. sel_weapon, 1.5)
end

local WEP_ACTION_ROWS = {
    { header = "AMMO (selected weapon)", buttons = {
        { label = "Max Ammo",    fn = function() set_sel_ammo(game_wep_modes.get_ammo_max(sel_weapon)) end },
        { label = "Refill 999",  fn = function() set_sel_ammo(999) end },
        { label = "Empty Ammo",  fn = function() set_sel_ammo(0) end },
    }},
    { header = "UPGRADES (selected weapon)", buttons = {
        { label = "Upgrades 100",   fn = function() set_sel_upgrades(100) end },
        { label = "Upgrades 1000",   fn = function() set_sel_upgrades(1000) end },
        { label = "Upgrades 10000",   fn = function() set_sel_upgrades(10000) end },
        { label = "Remove Upgrades",fn = function() set_sel_upgrades(0) end },
    }},
    { header = "EQUIP", buttons = {
        { label = "Equip Selected", fn = equip_sel },
    }},
}

local WEP_BTN_Y0 = 0.60
local function wep_buttons_layout(cb_section, cb_button)
    local by = WEP_BTN_Y0
    for _, row in ipairs(WEP_ACTION_ROWS) do
        if cb_section then cb_section(row.header, by) end
        by = by - 0.045
        local bx = 0.06
        local bw, bh = 0.20, 0.05
        for _, b in ipairs(row.buttons) do
            cb_button(b, bx, by, bw, bh)
            bx = bx + bw + 0.02
        end
        by = by - 0.085
    end
end

function p.init(wid)
    aspect = ga_get_sys_f("display.camera_params.a_ratio.value")
    if inited then return end
    inited = true
    compute_grid()
    ga_init_s(SEL_VAR, "")
    ga_win_enable_cursor(true)
    ga_win_show_cursor_icon(true)

    ga_init_s(FAV_VAR, "")
    ga_init_s(REC_VAR, "")
    ga_init_s(BR_SHAPE, "single")
    ga_init_i(BR_SIZE, 0)
    ga_init_i(E_COUNT, 1)
    ga_init_i(E_DIST, 4)
    ga_init_b(E_FREEZE, false)
    ga_init_b(E_ALLY, false)
    ga_init_i(E_TTL, 0)

    ga_win_widget_text_input_start(wid, 0.835, fix_charw(0.012), 0.024)
    ga_win_widget_text_input_set_text(wid, "")
    ga_win_widget_text_input_set_enable_enter(wid, false)

    ga_win_widget_button_start(wid, 1, 0.01,  0.91, 0.009, 0.018, "BLOCKS")
    ga_win_widget_button_start(wid, 2, 0.145, 0.91, 0.009, 0.018, "WEAPONS")
    ga_win_widget_button_start(wid, 3, 0.29,  0.91, 0.009, 0.018, "ITEMS")
    ga_win_widget_button_start(wid, 4, 0.41,  0.91, 0.009, 0.018, "BUFFS")
    ga_win_widget_button_start(wid, 5, 0.53,  0.91, 0.009, 0.018, "ENTITIES")
    ga_win_widget_button_start(wid, 6, 0.68,  0.91, 0.009, 0.018, "INTERACT")
    ga_win_widget_button_start(wid, 7, 0.83,  0.91, 0.009, 0.018, "TELEPORT")

    ga_win_widget_go_back_button_start(wid, 0.03, fix_charw(0.02), 0.04, "Close (ESC)")

    cur_tab = TAB_BLOCKS
    last_tab = -1
    last_search = nil
    rebuild(wid)
end

function p.__start(wid)    p.init(wid) end
function p.__end(wid)      inited = false; use_3d_mesh = nil end

function p.__process_input(wid)
    if ga_win_widget_go_back_button_process_input(wid) or ga_win_key_pressed(wid, "ESC") then
        ga_window_pop()
        return
    end

    local btn = ga_win_widget_button_process_input(wid)
    if btn ~= nil and btn >= 1 and btn <= TAB_COUNT then
        cur_tab = btn
    end
    if ga_win_key_pressed(wid, "TAB") then
        cur_tab = (cur_tab % TAB_COUNT) + 1
    end

    ga_win_widget_text_input_process_input(wid)
    local cur_search = ga_win_widget_text_input_get_text(wid)
    if cur_tab ~= last_tab or cur_search ~= last_search then
        last_tab = cur_tab
        last_search = cur_search
        rebuild(wid)
    end

    if cur_tab == TAB_BLOCKS or cur_tab == TAB_WEAPONS or cur_tab == TAB_ENTITIES
       or cur_tab == TAB_INTERACT or cur_tab == TAB_TELEPORT then
        local np = num_pages()
        if ga_win_mouse_wheel_down(wid) or ga_win_key_pressed_or_spammed(wid, "DOWN", 1.0, 0.05) then
            page = page + 1
        end
        if ga_win_mouse_wheel_up(wid) or ga_win_key_pressed_or_spammed(wid, "UP", 1.0, 0.05) then
            page = page - 1
        end
        if page < 0 then page = np - 1 end
        if page >= np then page = 0 end

        if ga_win_mouse_pressed(wid, true) then
            local cursor = ga_win_get_cursor_pos(wid)
            local gi = hovered_index(cursor)
            if gi >= 1 then
                if cur_tab == TAB_BLOCKS then
                    choose_block(gi)
                elseif cur_tab == TAB_WEAPONS then
                    choose_weapon(gi)
                elseif cur_tab == TAB_ENTITIES then
                    choose_entity(gi)
                elseif cur_tab == TAB_INTERACT then
                    choose_interactable(gi)
                elseif cur_tab == TAB_TELEPORT then
                    choose_teleport(gi)
                end
            end
        end

        if cur_tab == TAB_BLOCKS then
            local ok_rclick, rclick = ga_win_mouse_pressed(wid, false)
            if ok_rclick and rclick then
                local cursor = ga_win_get_cursor_pos(wid)
                local gi = hovered_index(cursor)
                if gi >= 1 and items[gi] then
                    local was = fav_toggle(items[gi].raw)
                    ga_hud_msg(was and ("Favorited: " .. items[gi].label) or ("Unfavorited: " .. items[gi].label), 1.5)
                    ga_play_sound("menu_select")
                end
            end
        end
    end

    if cur_tab == TAB_ITEMS and ga_win_mouse_pressed(wid, true) then
        local cursor = ga_win_get_cursor_pos(wid)
        local by = 0.78
        for _, section in ipairs(ITEM_BUTTONS) do
            local bx = 0.30
            for _, b in ipairs(section.buttons) do
                local bw = 0.12
                local bh = 0.035
                if btn_rect(cursor, bx, by - bh, bw, bh) then
                    if b.delta then
                        set_var("di " .. section.var .. " " .. tostring(b.delta))
                    else
                        set_var("i " .. section.var .. " " .. tostring(b.value))
                    end
                    ga_play_sound("menu_select")
                end
                bx = bx + bw + 0.01
            end
            by = by - 0.07
        end
    end

    if cur_tab == TAB_BUFFS and ga_win_mouse_pressed(wid, true) then
        local cursor = ga_win_get_cursor_pos(wid)
        local by = 0.78
        for _, section in ipairs(BUFF_BUTTONS) do
            by = by - 0.04
            local bx = 0.03
            for _, e in ipairs(section.entries) do
                local bw = 0.175
                local bh = 0.030
                if bx + bw > 0.97 then
                    bx = 0.03
                    by = by - 0.035
                end
                if btn_rect(cursor, bx, by - bh, bw, bh) then
                    if e.raw then
                        ga_command(e.raw)
                    elseif e.label == "ALL Keys 60s" then
                        set_var("f xar.key_time.yellow 60")
                        set_var("f xar.key_time.blue 60")
                        set_var("f xar.key_time.green 60")
                        set_var("f xar.key_time.universe 60")
                        set_var("f xar.key_time.laser_genesis 60")
                        set_var("f xar.key_time.dans_house 60")
                    else
                        set_var(e.cmd)
                    end
                    ga_play_sound("menu_select")
                end
                bx = bx + bw + 0.005
            end
            by = by - 0.075
        end
    end

    if cur_tab == TAB_WEAPONS and ga_win_mouse_pressed(wid, true) then
        local cursor = ga_win_get_cursor_pos(wid)
        wep_buttons_layout(nil, function(b, bx, by, bw, bh)
            if btn_rect(cursor, bx, by - bh, bw, bh) then
                b.fn()
                ga_play_sound("menu_select")
            end
        end)
    end

    if ga_win_mouse_pressed(wid, true) then
        local cursor = ga_win_get_cursor_pos(wid)
        local sy = 0.095
        local sh = 0.035

        if cur_tab == TAB_BLOCKS then
            local vx = 0.025
            local vw = 0.065
            if btn_rect(cursor, vx, sy, vw, sh) then
                view_mode = "ALL"; rebuild(wid); ga_play_sound("menu_select")
            end
            vx = vx + vw + 0.005
            if btn_rect(cursor, vx, sy, vw, sh) then
                view_mode = "FAV"; rebuild(wid); ga_play_sound("menu_select")
            end
            vx = vx + vw + 0.005
            if btn_rect(cursor, vx, sy, vw + 0.01, sh) then
                view_mode = "RECENT"; rebuild(wid); ga_play_sound("menu_select")
            end

            local sx = 0.33
            local sw = 0.065
            if btn_rect(cursor, sx, sy, sw, sh) then
                sort_mode = "NAME"; rebuild(wid); ga_play_sound("menu_select")
            end
            sx = sx + sw + 0.005
            if btn_rect2(cursor, sx, sy, sw + 0.02, sh) then
                sort_mode = "CATEGORY"
                rebuild(wid)
            end

            local bx = 0.52
            local bw = 0.060
            if btn_rect2(cursor, bx, sy, bw, sh) then
                ga_set_s(BR_SHAPE, "single")
                ga_set_i(BR_SIZE, 0)
            end
            bx = bx + bw + 0.005
            if btn_rect2(cursor, bx, sy, bw, sh) then
                ga_set_s(BR_SHAPE, "cube")
                if ga_get_i(BR_SIZE) < 1 then ga_set_i(BR_SIZE, 1) end
            end
            bx = bx + bw + 0.005
            if btn_rect2(cursor, bx, sy, bw + 0.005, sh) then
                ga_set_s(BR_SHAPE, "sphere")
                if ga_get_i(BR_SIZE) < 1 then ga_set_i(BR_SIZE, 1) end
            end

            local bsx = 0.77
            local bsw = 0.035
            if btn_rect2(cursor, bsx, sy, bsw, sh) then
                local s = ga_get_i(BR_SIZE)
                if s > 0 then ga_set_i(BR_SIZE, s - 1) end
            end
            bsx = bsx + bsw + 0.035
            if btn_rect2(cursor, bsx, sy, bsw, sh) then
                local s = ga_get_i(BR_SIZE)
                if s < 10 then ga_set_i(BR_SIZE, s + 1) end
            end

        elseif cur_tab == TAB_ENTITIES then
            local ex = 0.025
            local ew = 0.030
            if btn_rect2(cursor, ex, sy, ew, sh) then
                local c = ga_get_i(E_COUNT)
                if c > 1 then ga_set_i(E_COUNT, c - 1) end
            end
            ex = ex + ew + 0.035
            if btn_rect2(cursor, ex, sy, ew, sh) then
                local c = ga_get_i(E_COUNT)
                if c < 20 then ga_set_i(E_COUNT, c + 1) end
            end
            ex = ex + ew + 0.015
            if btn_rect2(cursor, ex, sy, ew, sh) then
                local d = ga_get_i(E_DIST)
                if d > 1 then ga_set_i(E_DIST, d - 1) end
            end
            ex = ex + ew + 0.035
            if btn_rect2(cursor, ex, sy, ew, sh) then
                local d = ga_get_i(E_DIST)
                if d < 50 then ga_set_i(E_DIST, d + 1) end
            end
            ex = ex + ew + 0.015
            local tw = 0.065
            if btn_rect2(cursor, ex, sy, tw, sh) then ga_toggle_b(E_FREEZE) end
            ex = ex + tw + 0.005
            if btn_rect2(cursor, ex, sy, tw, sh) then ga_toggle_b(E_ALLY) end
            ex = ex + tw + 0.015
            if btn_rect2(cursor, ex, sy, ew, sh) then
                local t = ga_get_i(E_TTL)
                if t > 0 then ga_set_i(E_TTL, t - 10) end
            end
            ex = ex + ew + 0.035
            if btn_rect2(cursor, ex, sy, ew, sh) then ga_set_i_by_delta(E_TTL, 10) end

        elseif cur_tab == TAB_TELEPORT then
            local tx = 0.025
            local tw = 0.12
            if btn_rect2(cursor, tx, sy, tw, sh) then
                local ok, err = game_base_wp_system.teleport_home()
                ga_hud_msg("Teleporting home...", 2.0)
                ga_window_pop()
            end
            tx = tx + tw + 0.01
            if btn_rect2(cursor, tx, sy, tw + 0.02, sh) then
                local level = ga_get_viewer_level()
                local off   = ga_get_viewer_offset()
                local bp    = std.lp_to_bp(off)
                ga_bent_add(level, bp, "bent_base_waypoint", 60.0 * 60.0 * 24.0 * 365.0)
                ga_hud_msg("Placed waypoint marker at your position", 2.0)
            end
        end
    end
end

function p.__render(wid)
    aspect = ga_get_sys_f("display.camera_params.a_ratio.value")
    ga_win_set_screen_coord_mode(wid, "screen")

    ga_win_set_background(wid, std.vec(0.04, 0.04, 0.06), 0.97)

    ga_win_set_char_size(wid, fix_charw(0.018), 0.036)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt_center(wid, 0.965, "CREATIVE INVENTORY")
    ga_win_set_front_color_default(wid)

    local tab_x   = { 0.01, 0.145, 0.29, 0.41, 0.53, 0.68, 0.83 }
    local tab_len = { 6, 7, 5, 5, 8, 8, 8 }
    local tx = tab_x[cur_tab]
    local tw = tab_len[cur_tab] * 0.0125
    ga_win_quad_color(wid, tx, 0.900, tx + tw, 0.905, std.vec(0.30, 0.85, 0.95))

    ga_win_set_char_size(wid, fix_charw(0.010), 0.020)
    ga_win_txt(wid, 0.02, 0.84, "SEARCH:")

    local sel = ga_get_s(SEL_VAR)
    if sel ~= nil and sel ~= "" then
        ga_win_set_char_size(wid, 0.009, 0.018)
        ga_win_set_front_color(wid, std.vec(1.0, 0.9, 0.3))
        ga_win_txt(wid, 0.02, 0.050, "Selected: " .. clean_name(sel))
        ga_win_set_front_color_default(wid)
    end

    ga_win_set_char_size(wid, 0.008, 0.016)
    ga_win_set_front_color(wid, std.vec(0.5, 0.5, 0.5))
    ga_win_txt_center(wid, 0.020, "TAB=tabs | Wheel=page | V=build | C/MMB=eyedrop | Bksp=undo | F6=warp | F7=home")
    ga_win_set_front_color_default(wid)

    if cur_tab == TAB_BLOCKS then
        render_grid_tab(wid, "block")
        render_control_strip_blocks(wid)
    elseif cur_tab == TAB_WEAPONS then
        render_grid_tab(wid, "weapon")
        render_wep_buttons(wid)
    elseif cur_tab == TAB_ITEMS then
        render_items_tab(wid)
    elseif cur_tab == TAB_BUFFS then
        render_buffs_tab(wid)
    elseif cur_tab == TAB_ENTITIES then
        render_grid_tab(wid, "entity")
        render_control_strip_entities(wid)
    elseif cur_tab == TAB_INTERACT then
        render_grid_tab(wid, "interact")
    elseif cur_tab == TAB_TELEPORT then
        render_teleport_tab(wid)
    end
end

function render_control_strip_blocks(wid)
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
    small_btn(wid, cursor, vx, sy, vw, sh, "ALL", view_mode == "ALL")
    vx = vx + vw + 0.005
    small_btn(wid, cursor, vx, sy, vw, sh, "* FAV", view_mode == "FAV")
    vx = vx + vw + 0.005
    small_btn(wid, cursor, vx, sy, vw + 0.01, sh, "RECENT", view_mode == "RECENT")

    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, 0.33, sy + sh + 0.008, "SORT")
    ga_win_set_front_color_default(wid)
    local sx = 0.33
    local sw = 0.065
    small_btn(wid, cursor, sx, sy, sw, sh, "A-Z", sort_mode == "NAME")
    sx = sx + sw + 0.005
    small_btn(wid, cursor, sx, sy, sw + 0.02, sh, "CATEGORY", sort_mode == "CATEGORY")

    local cur_shape = gets(BR_SHAPE, "single")
    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, 0.52, sy + sh + 0.008, "BRUSH")
    ga_win_set_front_color_default(wid)
    local bx = 0.52
    local bw = 0.060
    small_btn(wid, cursor, bx, sy, bw, sh, "SINGLE", cur_shape == "single")
    bx = bx + bw + 0.005
    small_btn(wid, cursor, bx, sy, bw, sh, "CUBE", cur_shape == "cube")
    bx = bx + bw + 0.005
    small_btn(wid, cursor, bx, sy, bw + 0.005, sh, "SPHERE", cur_shape == "sphere")

    local cur_size = ga_get_i(BR_SIZE)
    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, 0.77, sy + sh + 0.008, "SIZE")
    ga_win_set_front_color_default(wid)
    local bsx = 0.77
    local bsw = 0.035
    small_btn(wid, cursor, bsx, sy, bsw, sh, "-", false)
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(1, 1, 1))
    ga_win_txt(wid, bsx + bsw + 0.010, sy + sh * 0.5 - 0.008, tostring(cur_size))
    ga_win_set_front_color_default(wid)
    bsx = bsx + bsw + 0.035
    small_btn(wid, cursor, bsx, sy, bsw, sh, "+", false)

    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.4, 0.4, 0.4))
    ga_win_txt(wid, 0.88, sy + 0.010, "R-click = fav")
    ga_win_set_front_color_default(wid)
end

function render_control_strip_entities(wid)
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
    small_btn(wid, cursor, ex, sy, ew, sh, "-", false)
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(1, 1, 1))
    ga_win_txt(wid, ex + ew + 0.008, sy + sh * 0.5 - 0.008, tostring(ga_get_i(E_COUNT)))
    ga_win_set_front_color_default(wid)
    ex = ex + ew + 0.035
    small_btn(wid, cursor, ex, sy, ew, sh, "+", false)
    ex = ex + ew + 0.015

    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, ex, sy + sh + 0.008, "DIST")
    ga_win_set_front_color_default(wid)
    small_btn(wid, cursor, ex, sy, ew, sh, "-", false)
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(1, 1, 1))
    ga_win_txt(wid, ex + ew + 0.008, sy + sh * 0.5 - 0.008, tostring(ga_get_i(E_DIST)))
    ga_win_set_front_color_default(wid)
    ex = ex + ew + 0.035
    small_btn(wid, cursor, ex, sy, ew, sh, "+", false)
    ex = ex + ew + 0.015

    local tw = 0.065
    local freeze = ga_get_b(E_FREEZE)
    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, ex, sy + sh + 0.008, "")
    ga_win_set_front_color_default(wid)
    small_btn(wid, cursor, ex, sy, tw, sh, "FREEZE", freeze)
    ex = ex + tw + 0.005

    local ally = ga_get_b(E_ALLY)
    small_btn(wid, cursor, ex, sy, tw, sh, "ALLY", ally)
    ex = ex + tw + 0.015

    ga_win_set_char_size(wid, 0.007, 0.014)
    ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
    ga_win_txt(wid, ex, sy + sh + 0.008, "TTL(s)")
    ga_win_set_front_color_default(wid)
    small_btn(wid, cursor, ex, sy, ew, sh, "-", false)
    local ttl_val = ga_get_i(E_TTL)
    ga_win_set_char_size(wid, 0.010, 0.020)
    ga_win_set_front_color(wid, std.vec(1, 1, 1))
    ga_win_txt(wid, ex + ew + 0.008, sy + sh * 0.5 - 0.008, ttl_val == 0 and "INF" or tostring(ttl_val))
    ga_win_set_front_color_default(wid)
    ex = ex + ew + 0.035
    small_btn(wid, cursor, ex, sy, ew, sh, "+", false)
end

function render_teleport_tab(wid)
    render_grid_tab(wid, "teleport")

    local cursor = ga_win_get_cursor_pos(wid)
    local sy = 0.095
    local sh = 0.035

    ga_win_quad_color(wid, 0.02, sy - 0.003, 0.98, sy + sh + 0.003, std.vec(0.06, 0.06, 0.10))

    local tx = 0.025
    local tw = 0.12
    small_btn(wid, cursor, tx, sy, tw, sh, "HOME (F7)", false)
    tx = tx + tw + 0.01
    small_btn(wid, cursor, tx, sy, tw + 0.02, sh, "PLACE WP HERE", false)

    tx = tx + tw + 0.04
    ga_win_set_char_size(wid, 0.008, 0.016)
    ga_win_set_front_color(wid, std.vec(0.5, 0.5, 0.5))
    ga_win_txt(wid, tx, sy + 0.010, "Click a waypoint to warp | F6 = warp by search")
    ga_win_set_front_color_default(wid)
end

function render_wep_buttons(wid)
    local cursor = ga_win_get_cursor_pos(wid)

    ga_win_set_char_size(wid, 0.013, 0.026)
    ga_win_set_front_color(wid, std.vec(0.4, 0.9, 1.0))
    local ammo_txt = "   (ammo: " .. ga_get_i("xar.player.gun" .. sel_weapon .. ".ammo") .. ")"
    ga_win_txt(wid, 0.06, WEP_BTN_Y0 + 0.035, "Editing Weapon " .. sel_weapon .. ammo_txt .. "  (click a weapon above to switch)")
    ga_win_set_front_color_default(wid)

    wep_buttons_layout(
        function(header, by)
            ga_win_set_char_size(wid, 0.011, 0.022)
            ga_win_set_front_color(wid, std.vec(1.0, 0.7, 0.3))
            ga_win_txt(wid, 0.06, by, header)
            ga_win_set_front_color_default(wid)
        end,
        function(b, bx, by, bw, bh)
            local hovering = btn_rect(cursor, bx, by - bh, bw, bh)
            local col = hovering and std.vec(0.45, 0.35, 0.20) or std.vec(0.28, 0.22, 0.13)
            local padding = default_padding
            ga_win_quad_color(wid, bx - fix_charw(padding), by - bh - padding, bx + bw + fix_charw(padding), by + padding, std.vec(0.5, 0.4, 0.2))
            ga_win_quad_color(wid, bx, by - bh, bx + bw, by, col)
            ga_win_set_char_size(wid, 0.010, 0.020)
            ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
            ga_win_txt(wid, bx + 0.008, by - bh + 0.013, b.label)
            ga_win_set_front_color_default(wid)
        end)
end

function render_grid_tab(wid, mode)
    ga_win_set_char_size(wid, 0.009, 0.018)
    ga_win_set_front_color(wid, std.vec(0.7, 0.7, 0.3))
    ga_win_txt_center(wid, 0.810, "Page " .. (page + 1) .. "/" .. num_pages() .. "   (" .. #items .. " entries)")
    ga_win_set_front_color_default(wid)

    local gx0 = X0 - 0.006
    local gx1 = X0 + COLS * CW + 0.001
    local gy_top = Y0 + 0.010
    local gy_bot = Y0 - (ROWS - 1) * CH - (CH - GAPY) - 0.006
    ga_win_quad_color(wid, gx0 - 0.003, gy_bot - 0.003, gx1 + 0.003, gy_top + 0.003, std.vec(0.15, 0.15, 0.22))
    ga_win_quad_color(wid, gx0, gy_bot, gx1, gy_top, std.vec(0.08, 0.08, 0.12))

    local cursor = ga_win_get_cursor_pos(wid)
    local hov_gi, hov_li = hovered_index(cursor)

    for i = 0, PER_PAGE - 1 do
        local gi = page * PER_PAGE + i + 1
        local it = items[gi]
        if it ~= nil then
            local minx, miny, maxx, maxy = cell_rect(i)
            local sel_check = ga_get_s(SEL_VAR)
            local is_sel = (mode == "block" and it.raw == sel_check)
                        or (mode == "weapon" and it.raw == sel_weapon)
            local is_hov = (gi == hov_gi)

            local tex = ""
            if     mode == "block"    then tex = block_tex(it.raw)
            elseif mode == "entity"   then tex = ent_tex(it.raw)
            elseif mode == "interact" then tex = valid_tex(it.tex)
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
                ga_win_quad_color(wid, minx, miny, minx + fix_padding(t), maxy, fcol)
                ga_win_quad_color(wid, maxx - fix_padding(t), miny, maxx, maxy, fcol)
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
                ga_win_txt(wid, minx + 0.004, miny + (maxy - miny) * 0.5 - 0.005, fit(it.label, max_chars))
                ga_win_set_front_color_default(wid)
            end
        end
    end

    if hov_gi >= 1 then
        local it = items[hov_gi]
        local shown = (mode == "entity" or mode == "interact") and it.raw or it.label
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

function render_items_tab(wid)
    ga_win_set_char_size(wid, 0.012, 0.024)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt_center(wid, 0.810, "RESOURCE MANAGEMENT")
    ga_win_set_front_color_default(wid)

    local cursor = ga_win_get_cursor_pos(wid)
    local by = 0.78

    for _, section in ipairs(ITEM_BUTTONS) do
        ga_win_set_char_size(wid, 0.011, 0.022)
        ga_win_set_front_color(wid, std.vec(1.0, 0.9, 0.3))
        local cur_val = ga_get_i(section.var)
        ga_win_txt(wid, 0.03, by, section.section .. ": " .. tostring(cur_val))
        ga_win_set_front_color_default(wid)

        local bx = 0.30
        ga_win_set_char_size(wid, 0.009, 0.018)
        for _, b in ipairs(section.buttons) do
            local bw = 0.12
            local bh = 0.035
            local hovering = btn_rect(cursor, bx, by - bh, bw, bh)
            local col = hovering and std.vec(0.4, 0.6, 0.8) or std.vec(0.2, 0.3, 0.4)
            ga_win_quad_color(wid, bx, by - bh, bx + bw, by, col)
            local padding = default_padding
            ga_win_quad_color(wid, bx - fix_padding(padding), by - bh - padding, bx + bw + fix_padding(padding), by + padding, std.vec(0.35, 0.35, 0.5))
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
    ga_win_txt(wid, 0.03, by + 0.01, "XP Level: " .. tostring(xp_level) .. "   To Next: " .. tostring(xp_tnl))
    ga_win_set_front_color_default(wid)
end

function render_buffs_tab(wid)
    ga_win_set_char_size(wid, 0.012, 0.024)
    ga_win_set_front_color(wid, std.vec(0.9, 0.85, 0.5))
    ga_win_txt_center(wid, 0.810, "BUFFS & KEYS")
    ga_win_set_front_color_default(wid)

    local cursor = ga_win_get_cursor_pos(wid)
    local by = 0.78

    for _, section in ipairs(BUFF_BUTTONS) do
        ga_win_set_char_size(wid, 0.011, 0.022)
        ga_win_set_front_color(wid, std.vec(1.0, 0.7, 0.3))
        ga_win_txt(wid, 0.03, by, section.section)
        ga_win_set_front_color_default(wid)
        by = by - 0.04

        local bx = 0.03
        ga_win_set_char_size(wid, 0.008, 0.016)
        for _, e in ipairs(section.entries) do
            local bw = 0.175
            local bh = 0.030
            if bx + bw > 0.97 then
                bx = 0.03
                by = by - 0.035
            end
            local hovering = btn_rect(cursor, bx, by - bh, bw, bh)
            local col = hovering and std.vec(0.5, 0.4, 0.6) or std.vec(0.25, 0.20, 0.30)
            local padding = default_padding
            ga_win_quad_color(wid, bx - fix_padding(padding), by - bh - padding, bx + bw + fix_padding(padding), by + padding, std.vec(0.40, 0.30, 0.50))
            ga_win_quad_color(wid, bx, by - bh, bx + bw, by, col)
            ga_win_set_front_color(wid, std.vec(1.0, 1.0, 1.0))
            ga_win_txt(wid, bx + 0.004, by - bh + 0.007, e.label)
            ga_win_set_front_color_default(wid)
            bx = bx + bw + 0.005
        end
        by = by - 0.075
    end

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

    local god = ga_get_sys_b("metagame.cheat.god")
    timer_y = timer_y - 0.01
    if god then
        ga_win_set_front_color(wid, std.vec(0.4, 1.0, 0.4))
        ga_win_txt(wid, 0.03, timer_y, "GOD MODE: ON")
    else
        ga_win_set_front_color(wid, std.vec(0.6, 0.6, 0.6))
        ga_win_txt(wid, 0.03, timer_y, "GOD MODE: OFF")
    end
    ga_win_set_front_color_default(wid)
end

function p.uncrash__info()
    local out = uncrash.info {
        local_funcs={
            compute_grid=compute_grid,
            clean_name=clean_name,
            clean_ent_name=clean_ent_name,
            category_of=category_of,
            -- more!!!
        }
    }
    compute_grid=out.compute_grid
    clean_name=out.clean_name
    clean_ent_name=out.clean_ent_name
    category_of=out.category_of
end

-- why is this window file 1.5k lines