-- Creative menu: texture lookups (block / monster / interactable icons) and
-- display names, incl. entry_info() for hotbar entries. See win_creative_core.lua.
creative_ui = creative_ui or {}          -- shared by all win_creative*.lua files (one window Lua state)
creative_ui.state = creative_ui.state or {}
local C, S = creative_ui, creative_ui.state

local tex_set      = nil
local tex_norm     = nil
local tex_cache    = {}

C.INTERACT_LABEL = {
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
    bent_base_txt                 = "Text Box",
    ["@trophy"]                   = "Trophies (open list)",
}

-------------------------------------------------------------------------------
-- INTERACT pickups that need an amount: xar reads it from the basic ent's int
-- param (ga_bent_get_param_i), so placed without one they give 0 XP / 0
-- seconds. One amount per type in temp.creative.amt.<bent>; the game places
-- them with ga_bent_add_i (Game/game_creative_place.lua C.bent_amount - keep
-- the defaults equal). def = default, step = the - / + buttons, neg = may
-- be negative (XP: takes XP away; powerups: less time left; keys: key gone;
-- toll / blue key price: xar's pay code does gold >= price then gold - price,
-- so paying GIVES gold, clipped to the gold max by game_gold.set).
-- Huge ammo can't: xar only applies it when ammo goes UP (new > old), so a
-- negative one would be a pickup that does nothing.
-------------------------------------------------------------------------------
local XP    = { unit = "XP",   step = 100, presets = { 100, 1000, 10000, 100000 }, neg = true }
local SECS  = { unit = "sec",  step = 10,  presets = { 10, 30, 60, 300, 600 }, neg = true }
local AMMO  = { unit = "ammo", step = 10,  presets = { 10, 100, 1000, 10000 } }
local PRICE = { unit = "gold", step = 100, presets = { 0, 100, 1000, 10000, 100000 }, neg = true }
local function amt(kind, def)
    return { unit = kind.unit, step = kind.step, presets = kind.presets, def = def, neg = kind.neg == true }
end
C.AMOUNT_BENTS = {
    bent_xp                 = amt(XP, 1000),
    bent_damage_5x_stacking = amt(SECS, 30),
    bent_invun_stacking     = amt(SECS, 30),
    bent_xp_5x_stacking     = amt(SECS, 30),
    bent_key_yellow         = amt(SECS, 60),
    bent_key_green          = amt(SECS, 60),
    bent_key_universe       = amt(SECS, 60),
    bent_key_laser_genesis  = amt(SECS, 60),
    bent_key_dans_house     = amt(SECS, 60),
    bent_ammo_gun_2_huge    = amt(AMMO, 200),
    bent_ammo_gun_3_huge    = amt(AMMO, 200),
    bent_ammo_gun_4_huge    = amt(AMMO, 200),
    bent_ammo_gun_5_huge    = amt(AMMO, 2000),
    bent_ammo_gun_6_huge    = amt(AMMO, 1000),
    bent_ammo_gun_9_huge    = amt(AMMO, 100),
    bent_pay_toll           = amt(PRICE, 1000),
    bent_pay_toll_parent    = amt(PRICE, 1000),
    bent_pay_toll_parent2   = amt(PRICE, 1000),
    bent_buy_blue_key       = amt(PRICE, 1000),
}
C.AMOUNT_PREFIX = "temp.creative.amt."
C.AMOUNT_MAX    = 2147483647

function C.amount_get(raw)
    local a = C.AMOUNT_BENTS[raw]
    if a == nil then return nil end
    local var = C.AMOUNT_PREFIX .. raw
    if ga_exists(var) then
        local v = ga_get_i(var)
        if type(v) == "number" and (v >= 0 or a.neg) then return v end
    end
    return a.def
end

function C.amount_set(raw, n)
    local a = C.AMOUNT_BENTS[raw]
    if a == nil then return end
    n = math.floor(tonumber(n) or 0)
    local lo = a.neg and -C.AMOUNT_MAX or 0
    if n < lo then n = lo end
    if n > C.AMOUNT_MAX then n = C.AMOUNT_MAX end
    local var = C.AMOUNT_PREFIX .. raw
    if not ga_exists(var) then ga_init_i(var, n) end
    ga_set_i(var, n)
end

-- 1234567 -> "1,234,567"
function C.fmt_int(n)
    local s = tostring(math.floor(n))
    local neg = string.sub(s, 1, 1) == "-"
    if neg then s = string.sub(s, 2) end
    local out = string.gsub(string.reverse(s), "(%d%d%d)", "%1,")
    out = string.reverse(out)
    if string.sub(out, 1, 1) == "," then out = string.sub(out, 2) end
    return (neg and "-" or "") .. out
end

-- 100000 -> "100K"
function C.fmt_short(n)
    if n >= 1000000 and n % 1000000 == 0 then return (n / 1000000) .. "M" end
    if n >= 1000 and n % 1000 == 0 then return (n / 1000) .. "K" end
    return tostring(n)
end

-------------------------------------------------------------------------------
-- INTERACT ents with a text param (xar reads ga_bent_get_param_s). Placed with
-- ga_bent_add_s, or ga_bent_add_i + ga_bent_set_param_s when they also take an
-- amount (green key: seconds + combo). One value per type in
-- temp.creative.txt.<bent>; Game/game_creative_place.lua PARAM_S mirrors the
-- defaults and choice lists (the test checks they match).
--   kind "text"   = typed freely (the combo is only compared to a door's combo)
--   kind "choice" = picked with < >: these name game vars the ent reads/sets
--                   without checking them; an unknown name = an engine error
--                   that quits the game, so only names from xar globals.txt.
-- bent_env_var_open_door opens when its bool var is true; the "Unlock stable
-- singletons door" ent sets xar.door_unlocked.<area>, so those are its vars.
-- (bent_base_txt / bent_base_UNKNOWN take their text from the text box editor.)
-------------------------------------------------------------------------------
local SING_AREAS = { "i1", "i2", "i3", "hell", "burlington" }
local DOOR_VARS = {}
for i, a in ipairs(SING_AREAS) do DOOR_VARS[i] = "xar.door_unlocked." .. a end
C.PARAM_BENTS = {
    bent_key_green           = { kind = "text", def = "", label = "COMBO (must match the green door's)", what = "combo" },
    bent_open_green_door     = { kind = "text", def = "", label = "COMBO (must match the green key's)", what = "combo" },
    bent_unlock_stable_sing  = { kind = "choice", def = "i1", label = "AREA (unlocks xar.door_unlocked.<area>)",
                                 what = "area", choices = SING_AREAS },
    bent_env_var_open_door   = { kind = "choice", def = "xar.door_unlocked.i1", label = "OPENS WHEN THIS VAR IS TRUE",
                                 what = "var", choices = DOOR_VARS },
    bent_upgrade_telekinesis = { kind = "choice", def = "stone_corral", label = "UPGRADE",
                                 what = "upgrade", choices = {
        "stone_corral", "huntington", "starksboro", "desert_flower_cloud", "tangerine",
        "super_massive_black_hole", "top_of_world", "absolute_infinite", "main_branch_lib",
        "mylantis_great_cavern", "secret_farmhouse", "beta_sponge" } },
}
C.PARAM_PREFIX = "temp.creative.txt."

local function choice_index(p, s)
    for i, c in ipairs(p.choices) do if c == s then return i end end
    return nil
end

function C.param_get(raw)
    local p = C.PARAM_BENTS[raw]
    if p == nil then return nil end
    local var = C.PARAM_PREFIX .. raw
    if ga_exists(var) then
        local s = ga_get_s(var)
        if type(s) == "string" and (p.kind == "text" or choice_index(p, s)) then return s end
    end
    return p.def
end

function C.param_set(raw, s)
    local p = C.PARAM_BENTS[raw]
    if p == nil or type(s) ~= "string" then return end
    if p.kind == "choice" and not choice_index(p, s) then return end
    local var = C.PARAM_PREFIX .. raw
    if not ga_exists(var) then ga_init_s(var, s) end
    ga_set_s(var, s)
end

-- choice params: step d (+1 / -1) through the list, wrapping
function C.param_cycle(raw, d)
    local p = C.PARAM_BENTS[raw]
    if p == nil or p.kind ~= "choice" then return end
    local i = choice_index(p, C.param_get(raw)) or 1
    C.param_set(raw, p.choices[(i - 1 + d) % #p.choices + 1])
end

-- " (1,000 XP)" / " (60 sec, combo abc)" for an ent with an amount and / or a
-- text param, "" otherwise
function C.bent_suffix(raw)
    local parts = {}
    local a = C.AMOUNT_BENTS[raw]
    if a ~= nil then parts[#parts + 1] = C.fmt_int(C.amount_get(raw)) .. " " .. a.unit end
    local p = C.PARAM_BENTS[raw]
    if p ~= nil then
        local s = C.param_get(raw)
        parts[#parts + 1] = p.what .. " " .. ((s == "") and "(none)" or s)
    end
    if #parts == 0 then return "" end
    return " (" .. table.concat(parts, ", ") .. ")"
end

function C.clean_name(raw)
    if string.sub(raw, 1, 4) == "XAR_" then return string.sub(raw, 5) end
    return raw
end

function C.clean_ent_name(raw)
    local s = raw
    if string.sub(s, 1, 13) == "ment_monster_" then s = string.sub(s, 14) end
    if string.sub(s, 1, 5) == "ment_" then s = string.sub(s, 6) end
    s = string.gsub(s, "_", " ")
    s = string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
    return s
end

-------------------------------------------------------------------------------
-- ENTITIES display names = what the game shows when you shoot the monster:
-- the ment type's "identity_str" string var (xar game_ment_identify.get_str).
-- ga_ment_get_static_s on a missing / non-string var is an engine PoliteExit
-- (the game quits), so it is only read after ga_ment_type_var_exists.
-- Key guards' identity_str is their "YOU NEED A ... KEY TO PASS BY" message,
-- so they get "Key Guard (Blue)" etc. Types without one keep clean_ent_name.
-- Built once for every ment type so names shared by two types (Inner Core,
-- Blue Lamprey, Baby Spider) get the id words the name lacks: "Inner Core
-- (Genesis)", "Blue Lamprey (Immune)", "Baby Spider (Rocket)".
-------------------------------------------------------------------------------

local function title_case(s)
    s = string.gsub(s, "_", " ")
    return (string.gsub(s, "(%a)([%w']*)", function(a, b) return string.upper(a) .. b end))
end

local function ment_identity(raw)
    if ga_ment_type_var_exists == nil or ga_ment_get_static_s == nil then return nil end
    if not ga_ment_type_var_exists(raw, "identity_str") then return nil end
    local s = ga_ment_get_static_s(raw, "identity_str")
    if type(s) ~= "string" then return nil end
    s = string.gsub(string.gsub(s, "^%s+", ""), "%s+$", "")
    if s == "" then return nil end
    return s
end

local function ent_base_label(raw)
    if string.sub(raw, 1, 15) == "ment_key_guard_" then
        return "Key Guard (" .. title_case(string.sub(raw, 16)) .. ")"
    end
    return ment_identity(raw) or C.clean_ent_name(raw)
end

-- id words (minus ment / monster) that the label does not already contain
local function ent_extra_words(raw, label)
    local have = {}
    for w in string.gmatch(string.lower(label), "%w+") do have[w] = true end
    local extra = {}
    for t in string.gmatch(raw, "[^_]+") do
        if t ~= "ment" and t ~= "monster" and not have[t] then extra[#extra + 1] = t end
    end
    return title_case(table.concat(extra, " "))
end

local ent_labels = nil   -- raw -> display name

local function build_ent_labels()
    ent_labels = {}
    local arr = nil
    if ga_get_ment_names_with_prefix ~= nil then
        arr = ga_get_ment_names_with_prefix("")
        if arr == nil or #arr == 0 then arr = ga_get_ment_names_with_prefix("ment_") end
    end
    local groups, order = {}, {}
    for _, v in ipairs(arr or {}) do
        local raw = (type(v) == "table") and v.name or v
        if type(raw) == "string" and ent_labels[raw] == nil then
            local lbl = ent_base_label(raw)
            ent_labels[raw] = lbl
            if groups[lbl] == nil then groups[lbl] = {}; order[#order + 1] = lbl end
            table.insert(groups[lbl], raw)
        end
    end
    for _, lbl in ipairs(order) do
        local g = groups[lbl]
        if #g > 1 then
            for _, raw in ipairs(g) do
                local extra = ent_extra_words(raw, lbl)
                if extra ~= "" then ent_labels[raw] = lbl .. " (" .. extra .. ")" end
            end
        end
    end
end

-- display name for a ment type (ENTITIES grid, hotbar)
function C.ent_label(raw)
    if ent_labels == nil then build_ent_labels() end
    local l = ent_labels[raw]
    if l == nil then                 -- a type the enumeration did not return
        l = ent_base_label(raw)
        ent_labels[raw] = l
    end
    return l
end

function C.category_of(clean)
    return string.match(clean, "^[^_]+") or clean
end

function C.cat_color(cat)
    local h = 0
    for i = 1, #cat do h = (h * 31 + string.byte(cat, i)) % 100003 end
    local r = 0.25 + (h % 55) / 100
    local g = 0.25 + (math.floor(h / 7) % 55) / 100
    local b = 0.25 + (math.floor(h / 53) % 55) / 100
    return std.vec(r, g, b)
end

local DROP_TOKENS = { solid = true, boring = true, block = true, xar = true }

local TEX_FALLBACK_PREFIXES = {
    "Monster", "block_", "ent_", "bent_", "key_", "buy_", "sell_", "upgrade_",
    "gold_", "health_", "armor_", "ammo_", "sleep", "pay_", "black_", "arcade_",
    "genesis_", "cheap_", "invun", "damage_", "xp", "shield", "spice", "trophy",
    "icarus", "secret_", "marker_", "WhiteBox", "YellowBox", "Drop", "icon_", "pic_",
    "picture_", "ring_",
}

local function norm_key(s)
    return (string.gsub(string.lower(s), "[^%w]", ""))
end

function C.ensure_tex_set()
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

function C.ntex(name)
    if name == nil or name == "" then return nil end
    C.ensure_tex_set()
    return tex_norm[norm_key(name)]
end

local function fuzzy_tex(base, prefix, drop)
    local toks = {}
    for t in string.gmatch(base, "[^_]+") do
        if not drop[t] then toks[#toks + 1] = t end
    end
    for start = 1, #toks do
        local cand = C.ntex(prefix .. table.concat(toks, "_", start))
        if cand then return cand end
    end
    for stop = #toks, 1, -1 do
        local cand = C.ntex(prefix .. table.concat(toks, "_", 1, stop))
        if cand then return cand end
    end
    return ""
end

function C.block_tex(raw)
    local cached = tex_cache[raw]
    if cached ~= nil then return cached end
    C.ensure_tex_set()
    local found
    if raw:sub(1,6) == "block_" then
        -- grab the texture from the module like a normal person
        if _G[raw] and _G[raw].__get_tex then
            found = _G[raw].__get_tex() -- returns "" if no texture.
        elseif _G[raw] and _G[raw].__get_bt_to_copy then -- new 1.02.00 feature
            found = C.block_tex(_G[raw].__get_bt_to_copy())
        end
    else
        found = fuzzy_tex(string.lower(C.clean_name(raw)), "block_", DROP_TOKENS)
    end
    -- TODO error handling here
    found = found or ""
    tex_cache[raw] = found
    return found
end

local ENT_FILLER = { ment = true, monster = true, guard = true, general = true, the = true }
local ENT_TEX_OVERRIDE = { ment_general_drop_box = "Drop" }
local ent_tex_cache = {}

function C.ent_tex(raw)
    local cached = ent_tex_cache[raw]
    if cached ~= nil then return cached end
    C.ensure_tex_set()
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
            local m = C.ntex("monster" .. joined) or C.ntex(joined)
            if m then found = m; break end
        end
    end
    ent_tex_cache[raw] = found
    return found
end

function C.valid_tex(name)
    return C.ntex(name) or ""
end

-- Draws a square texture icon with bottom-left at (x, y) and height h; width is
-- aspect-corrected so it stays square. Unknown textures are skipped (returns 0),
-- so a renamed game texture can never break the menu. Returns the drawn width.
function C.draw_icon(wid, x, y, h, name, framed)
    local tex = C.ntex(name)
    if tex == nil then return 0 end
    local w = h / S.aspect
    if framed then
        local f = 0.002
        ga_win_quad_color(wid, x - f / S.aspect, y - f, x + w + f / S.aspect, y + h + f, std.vec(0.0, 0.0, 0.0))
    end
    ga_win_quad(wid, x, y, x + w, y + h, tex)
    return w
end

function C.clean_bent_name(raw)
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

function C.bent_tex(raw)
    local cached = bent_tex_cache[raw]
    if cached ~= nil then return cached end
    C.ensure_tex_set()
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
            local m = (tex_set[cd] and cd) or C.ntex(cd)
            if m then found = m; break end
        end
    end
    bent_tex_cache[raw] = found
    return found
end

function C.nice_name(s)
    s = string.gsub(s, "_", " ")
    return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

-------------------------------------------------------------------------------
-- Hotbar entries: display name + icon texture for a "kind|raw" entry
-------------------------------------------------------------------------------

local entry_cache = {}
function C.entry_info(kind, raw)
    local key = kind .. "|" .. raw
    local c = entry_cache[key]
    if c then
        if kind == "bent" then return c.label .. C.bent_suffix(raw), c.tex end
        return c.label, c.tex
    end
    local label, tex = raw, ""
    if kind == "block" then
        label = (string.gsub(C.clean_name(raw), "_", " "))
        tex = C.block_tex(raw)
    elseif kind == "ment" then
        label, tex = C.ent_label(raw), C.ent_tex(raw)
    elseif kind == "bent" then
        label, tex = C.INTERACT_LABEL[raw] or C.clean_bent_name(raw), C.valid_tex(C.bent_tex(raw))
    elseif kind == "picture" then
        label, tex = C.nice_name(string.sub(raw, 9)), C.valid_tex(raw)
    elseif kind == "trophy" then
        label, tex = "Trophy: " .. C.nice_name(raw), C.valid_tex("trophy_" .. raw)
    elseif kind == "secret" then
        label, tex = "Secret trophy: " .. C.nice_name((string.gsub(raw, "^st_", ""))), C.valid_tex("secret_trophy")
    elseif kind == "path" then
        label, tex = (raw == "blue") and "Blue Path" or "Pink Path", C.valid_tex("ring_" .. raw)
    end
    tex = tex or ""
    entry_cache[key] = { label = label, tex = tex }
    if kind == "bent" then label = label .. C.bent_suffix(raw) end   -- changes, so not cached
    return label, tex
end

-- every texture name the game has (lists use it to find picture_* / trophy_*)
function C.get_tex_set()
    C.ensure_tex_set()
    return tex_set
end

-- not a real window: only here so the window Lua state loads it
function p.__start(wid) end
function p.__end(wid) end
function p.__on_start(wid) end
function p.__on_end(wid) end
function p.__render(wid) end
function p.__process_input(wid) end
