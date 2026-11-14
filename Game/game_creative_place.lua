-- Creative mode (game side): placing non-blocks (monsters, interactables,
-- pictures, trophies, text boxes, pink/blue paths) and what right click removes.
-- See game_creative_core.lua for how the files share things.
creative_g = creative_g or {}           -- shared by all game_creative*.lua files (one game Lua state)
creative_g.state = creative_g.state or {}
local C, S = creative_g, creative_g.state

-------------------------------------------------------------------------------
-- Non-block placement (ments, bents, pictures, trophies)
-------------------------------------------------------------------------------

-- picture_* textures that are not square (measured from the image files)
local function set_of(t) local o = {} for _, v in ipairs(t) do o[v] = true end return o end
local PIC_WIDE = set_of{
    "picture_old_house", "picture_dragon", "picture_keiths", "picture_belle_rosette",
    "picture_tau_caves", "picture_inf2_1", "picture_inf2_2", "picture_inf2_3",
    "picture_inf2_4", "picture_inf2_5", "picture_inf2_6", "picture_inf2_7",
    "picture_inf2_8", "picture_petroglyphs", "picture_block_arena_1", "picture_block_arena_2",
}
local PIC_TALL = set_of{
    "picture_flower_girl", "picture_cred_dan", "picture_cred_bruce", "picture_cred_joan",
    "picture_cred_jon", "picture_cred_tegan", "picture_cred_zach", "picture_orange",
    "picture_base_camp", "picture_portal_back_to_i2", "picture_corn_maze", "picture_cot_ophelia",
    "picture_cot_spring_high", "picture_cot_spring", "picture_m_to_omega",
}
local DECOR_SCALE = { 0.6, 1.0, 1.8, 3.0 }   -- S M L XL (DECOR tab "PIC SIZE")

local function nice(s)
    s = string.gsub(s, "_", " ")
    return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

-- ENTITIES "FREEZE": the spawned monster is frozen exactly like a laser hit
-- (xar Game/MEnt/game_ment_freeze.laser_initial_hit: ice texture, no turning,
-- no moving, "frozen" flag the AI checks), just for a very long time. Like the
-- laser, freeze-immune monsters only get the 1 s stun and some can't be frozen
-- at all; non-monsters (no "frozen" var) are only stopped from moving/turning.
local FREEZE_LEN = 60.0 * 60.0 * 24.0 * 365.0

local function freeze_ment(id)
    if type(game_ment_freeze) == "table" and game_ment_freeze.laser_initial_hit then
        game_ment_freeze.laser_initial_hit(id, FREEZE_LEN, false)
    end
end

local function spawn_ments(raw)
    local level, pos, look = C.aim_point(0.5)
    local count = ga_get_i("temp.creative.ent_count")
    local ttl   = ga_get_i("temp.creative.ent_ttl")
    local freeze = ga_get_b("temp.creative.ent_freeze")
    if count < 1 then count = 1 end
    if count > 20 then count = 20 end
    -- spread several side by side, perpendicular to the look dir (world up = +Z)
    local px, py = -look.y, look.x
    local plen = math.sqrt(px * px + py * py)
    if plen < 0.0001 then px, py = 1, 0 else px, py = px / plen, py / plen end
    for i = 1, count do
        local s = 0
        if count > 1 then s = (i - (count + 1) / 2) * 1.5 end
        local at = std.vec(pos.x + px * s, pos.y + py * s, pos.z)
        ga_ment_start(level, at, raw)
        if freeze then
            ga_ment_init_set_b("__vel_disabled", true)
            ga_ment_init_set_b("__turning_disabled", true)
        end
        if ttl > 0 then ga_ment_init_set_f("__ttl", ttl * 1.0) end
        local id = ga_ment_end()
        if freeze and type(id) == "number" and id >= 0 then
            local ok, err = pcall(freeze_ment, id)
            if not ok then ga_console_print("creative freeze error: " .. tostring(err)) end
        end
    end
end

-------------------------------------------------------------------------------
-- Pictures are basic ents (BasicEnts/bent_creative_picture.lua) that draw the
-- picture themselves. xar's ment_picture_* ments are world-gen props: when
-- their chunk unloads (walking away, grow/shrink) only the engine's own vars
-- are saved, not the texture / size / facing / ttl we set, so they came back
-- with the type's 1 hour ttl and expired at once. A basic ent is saved
-- exactly: its block + one string "tex|w|h|fx|fy|ox|oy|oz".
-------------------------------------------------------------------------------

C.PIC_BENT = "bent_creative_picture"
-- size in blocks at "M" (about what the old ment pictures measured)
local PIC_SQUARE, PIC_WIDE_WH, PIC_TALL_WH = { 5.1, 5.1 }, { 10.4, 5.9 }, { 5.1, 9.1 }

local function pic_encode(d)
    return string.format("%s|%.3f|%.3f|%.4f|%.4f|%.3f|%.3f|%.3f",
        d.tex, d.w, d.h, d.fx, d.fy, d.ox, d.oy, d.oz)
end

-- same format as bent_creative_picture.decode (kept here so removal works
-- even if that module failed to load)
local function pic_decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local f = {}
    for part in string.gmatch(s, "[^|]+") do f[#f + 1] = part end
    if #f < 8 then return nil end
    local n = {}
    for i = 2, 8 do
        n[i] = tonumber(f[i])
        if n[i] == nil then return nil end
    end
    return { tex = f[1], w = n[2], h = n[3], fx = n[4], fy = n[5], ox = n[6], oy = n[7], oz = n[8] }
end

-- the picture bent at bp (or nil); adds its centre c (viewer coords)
local function bent_picture(level, bp)
    local ok, t = pcall(ga_bent_get_type, level, bp)
    if not ok or t ~= C.PIC_BENT then return nil end
    local ok2, s = pcall(ga_bent_get_param_s, level, bp)
    if not ok2 then return nil end
    local d = pic_decode(s)
    if d == nil then return nil end
    d.c = std.vec(bp.x + 0.5 + d.ox, bp.y + 0.5 + d.oy, bp.z + 0.5 + d.oz)
    return d
end

-- Where L-click would put picture raw: { level, bp, tex, w, h, fx, fy, ox, oy, oz, c }
function C.picture_placement(raw)
    local level, pos, look, hit, eye = C.aim_point(0.5)
    -- fx, fy = the direction you look INTO the picture
    local fx, fy
    if hit ~= nil and hit.n.z == 0 then
        -- aiming at a wall: hang it flat on the wall, facing out
        fx, fy = -hit.n.x, -hit.n.y
        local hx = eye.x + look.x * hit.t
        local hy = eye.y + look.y * hit.t
        local hz = eye.z + look.z * hit.t
        pos = std.vec(hx + hit.n.x * 0.05, hy + hit.n.y * 0.05, hz)
    else
        fx, fy = look.x, look.y
        local len = math.sqrt(fx * fx + fy * fy)
        if ga_get_b("temp.creative.decor_snap") or len < 0.0001 then
            if math.abs(fx) >= math.abs(fy) then
                fx, fy = (fx >= 0) and 1 or -1, 0
            else
                fx, fy = 0, (fy >= 0) and 1 or -1
            end
        else
            fx, fy = fx / len, fy / len
        end
    end
    local wh = PIC_SQUARE
    if PIC_WIDE[raw] then wh = PIC_WIDE_WH elseif PIC_TALL[raw] then wh = PIC_TALL_WH end
    local scale = DECOR_SCALE[ga_get_i("temp.creative.decor_size")] or 1.0
    local bp = std.lp_to_bp(pos)
    return {
        level = level, bp = bp, tex = raw, w = wh[1] * scale, h = wh[2] * scale, fx = fx, fy = fy,
        ox = pos.x - (bp.x + 0.5), oy = pos.y - (bp.y + 0.5), oz = pos.z - (bp.z + 0.5), c = pos,
    }
end

local function place_picture(raw)
    local pl = C.picture_placement(raw)
    local ok, there = pcall(ga_bent_get_type, pl.level, pl.bp)
    if ok and type(there) == "string" and there ~= "" then
        -- one basic ent per block cell
        ga_hud_msg("Something (" .. there .. ") is already in that spot - aim a little to the side", 2.0)
        return
    end
    ga_bent_add_s(pl.level, pl.bp, C.PIC_BENT, pic_encode(pl), C.BIG_TTL)
end

-------------------------------------------------------------------------------
-- Text boxes = base's "Read text" basic ent (bent_base_txt): the message is its
-- string param (^xRRGGBB colours, ^! back to normal, newlines; the engine
-- quotes it when saving). L-click opens Windows/win_creative_text.lua to type
-- it; that window hands it back through TXT_MSG / TXT_STATE and
-- finish_text_box() (every tick) places the ent. The spot is kept as an
-- anchor because the viewer-centric grid shifts if you move meanwhile.
-------------------------------------------------------------------------------

-- base's text ents: bent_base_txt ("Read text") and bent_base_UNKNOWN (a "?"
-- that shows the same kind of text box); both take the message as param_s
local TXT_BENTS = { bent_base_txt = "Text box", bent_base_UNKNOWN = "Base UNKNOWN" }
local TXT_MSG   = "temp.creative.text_msg"     -- also pre-fills the next text box
local TXT_STATE = "temp.creative.text_state"   -- "" | "edit" | "commit" | "cancel"
S.text_pending = nil                       -- { level, anchor, bent }

local function begin_text_box(level, bp, bent)
    local ok, there = pcall(ga_bent_get_type, level, bp)
    if ok and type(there) == "string" and there ~= "" then
        ga_hud_msg("Something (" .. there .. ") is already in that spot - aim a little to the side", 2.0)
        return
    end
    C.chunk_cache_reset()
    local anchor = C.anchor_make(level, bp)
    if anchor == nil then
        ga_hud_msg("Text: nothing loaded there", 1.5)
        return
    end
    S.text_pending = { level = level, anchor = anchor, bent = bent }
    ga_set_s(TXT_STATE, "edit")
    ga_window_push("win_creative_text")
end

function C.finish_text_box()
    local state = ga_get_s(TXT_STATE)
    if state ~= "commit" and state ~= "cancel" then return end
    ga_set_s(TXT_STATE, "")
    local pend = S.text_pending
    S.text_pending = nil
    if state == "cancel" or pend == nil then return end
    local msg = ga_get_s(TXT_MSG)
    if msg == "" then
        ga_hud_msg("Text: empty message, nothing placed", 1.5)
        return
    end
    C.chunk_cache_reset()
    local bp = C.anchor_bp(pend.anchor)
    if bp == nil then
        ga_hud_msg("Text: that spot is no longer loaded", 2.0)
        return
    end
    local bent = TXT_BENTS[pend.bent] and pend.bent or "bent_base_txt"
    ga_bent_add_s(pend.level, bp, bent, msg, C.BIG_TTL)
    ga_hud_msg(TXT_BENTS[bent] .. " placed (F on it to read)", 1.5)
end

-------------------------------------------------------------------------------
-- INTERACT pickups whose amount is the basic ent's int param (xar reads it
-- with ga_bent_get_param_i: XP, seconds of a powerup / key, huge ammo, toll
-- or blue key price). Placed with ga_bent_add_i; plain ga_bent_add = 0.
-- The menu keeps one amount per type in temp.creative.amt.<bent>
-- (Windows/win_creative_tex.lua C.AMOUNT_BENTS - keep the defaults equal).
-------------------------------------------------------------------------------
local AMOUNT_DEFAULT = {
    bent_xp = 1000,
    bent_damage_5x_stacking = 30, bent_invun_stacking = 30, bent_xp_5x_stacking = 30,
    bent_key_yellow = 60, bent_key_green = 60, bent_key_universe = 60,
    bent_key_laser_genesis = 60, bent_key_dans_house = 60,
    bent_ammo_gun_2_huge = 200, bent_ammo_gun_3_huge = 200, bent_ammo_gun_4_huge = 200,
    bent_ammo_gun_5_huge = 2000, bent_ammo_gun_6_huge = 1000, bent_ammo_gun_9_huge = 100,
    bent_pay_toll = 1000, bent_pay_toll_parent = 1000, bent_pay_toll_parent2 = 1000,
    bent_buy_blue_key = 1000,
}
C.AMOUNT_PREFIX = "temp.creative.amt."

-- amount for bent type raw, or nil if it takes none
function C.bent_amount(raw)
    local d = AMOUNT_DEFAULT[raw]
    if d == nil then return nil end
    local var = C.AMOUNT_PREFIX .. raw
    if ga_exists(var) then
        local v = ga_get_i(var)
        -- (the menu only lets XP / powerups / keys go negative)
        if type(v) == "number" then return v end
    end
    return d
end

-------------------------------------------------------------------------------
-- INTERACT ents with a text param (xar: ga_bent_get_param_s): green key /
-- green door combo (free text), stable-singletons area, env-var door var,
-- telekinesis upgrade name. The choice ones name game vars that xar reads /
-- sets without checking, so only these names are ever placed (an unknown
-- one = an engine error that quits the game). Same table as
-- Windows/win_creative_tex.lua C.PARAM_BENTS; value in temp.creative.txt.<bent>.
-------------------------------------------------------------------------------
local SING_AREAS = { "i1", "i2", "i3", "hell", "burlington" }
local DOOR_VARS = {}
for i, a in ipairs(SING_AREAS) do DOOR_VARS[i] = "xar.door_unlocked." .. a end
local PARAM_S = {
    bent_key_green           = { def = "" },
    bent_open_green_door     = { def = "" },
    bent_unlock_stable_sing  = { def = "i1", choices = SING_AREAS },
    bent_env_var_open_door   = { def = "xar.door_unlocked.i1", choices = DOOR_VARS },
    bent_upgrade_telekinesis = { def = "stone_corral", choices = {
        "stone_corral", "huntington", "starksboro", "desert_flower_cloud", "tangerine",
        "super_massive_black_hole", "top_of_world", "absolute_infinite", "main_branch_lib",
        "mylantis_great_cavern", "secret_farmhouse", "beta_sponge" } },
}
C.PARAM_PREFIX = "temp.creative.txt."

local function param_ok(p, s)
    if type(s) ~= "string" then return false end
    if p.choices == nil then return #s <= 64 end
    for _, c in ipairs(p.choices) do if c == s then return true end end
    return false
end

-- text param for bent type raw, or nil if it takes none
function C.bent_param_s(raw)
    local p = PARAM_S[raw]
    if p == nil then return nil end
    local var = C.PARAM_PREFIX .. raw
    if ga_exists(var) then
        local s = ga_get_s(var)
        if param_ok(p, s) then return s end
    end
    return p.def
end

-- eyedropper: remember a picked ent's text param (only valid values)
function C.bent_param_remember(raw, s)
    local p = PARAM_S[raw]
    if p == nil or not param_ok(p, s) then return false end
    local var = C.PARAM_PREFIX .. raw
    if not ga_exists(var) then ga_init_s(var, s) end
    ga_set_s(var, s)
    return true
end

function C.place_nonblock(kind, raw)
    if kind == "ment" then
        spawn_ments(raw)
    elseif kind == "picture" then
        place_picture(raw)
    else
        local level, pos = C.aim_point(0.5)
        local bp = std.lp_to_bp(pos)
        if kind == "bent" and TXT_BENTS[raw] then
            begin_text_box(level, bp, raw)
        elseif kind == "bent" then
            local amount, str = C.bent_amount(raw), C.bent_param_s(raw)
            if amount ~= nil then
                ga_bent_add_i(level, bp, raw, amount, C.BIG_TTL)
                if str ~= nil then ga_bent_set_param_s(level, bp, str, C.BIG_TTL) end
            elseif str ~= nil then
                ga_bent_add_s(level, bp, raw, str, C.BIG_TTL)
            else
                ga_bent_add(level, bp, raw, C.BIG_TTL)
            end
        elseif kind == "secret" then
            ga_bent_add_s(level, bp, "bent_secret_trophy", raw, C.BIG_TTL)
        elseif kind == "trophy" then
            ga_block_change_perm(level, bp, C.TROPHY_BLOCK)
            ga_block_set_s(level, bp, "api_name", raw)
        end
    end
end

-------------------------------------------------------------------------------
-- Right click removal. Targets: { what = "ment", id, t } |
-- { what = "bent", level, bp, t } | { what = "block", level, bp, t } (trophy).
--
-- crosshair_target() = the nearest non-block thing ON the crosshair that is in
-- front of the looked-at block. It ignores the hotbar kind, so shops, pictures
-- and trophies come off whatever slot is selected. The block look-ray can't see
-- them: bents (shops etc.) sit in empty cells, trophy blocks are non-solid and
-- pictures are ments, so a block slot used to break the wall BEHIND them.
-------------------------------------------------------------------------------

local REACH        = 40    -- how far right click looks when no block is aimed at
local TROPHY_REACH = 24    -- cells walked along the ray looking for trophy blocks
local MENT_MARGIN  = 20    -- extra sphere-query radius (XL wide pictures are ~18)

local function is_picture(t)
    return type(t) == "string" and string.sub(t, 1, 13) == "ment_picture_"
end

-- Ray (o + t*dir) vs a picture bent's rectangle (d from bent_picture). t or nil.
local function ray_picture_t(o, dir, d)
    local dn = dir.x * d.fx + dir.y * d.fy
    if math.abs(dn) < 1e-6 then return nil end
    local t = ((d.c.x - o.x) * d.fx + (d.c.y - o.y) * d.fy) / dn
    if t < 0 then return nil end
    local hx = o.x + dir.x * t - d.c.x
    local hy = o.y + dir.y * t - d.c.y
    local hz = o.z + dir.z * t - d.c.z
    local u = hx * d.fy - hy * d.fx          -- along the picture's width
    if math.abs(u) <= d.w * 0.5 and math.abs(hz) <= d.h * 0.5 then return t end
    return nil
end

-- crosshair target for the bent at bp: pictures by their rectangle, the
-- rest by their block cell
local function bent_target(level, o, dir, bp)
    local d = bent_picture(level, bp)
    if d ~= nil then
        return { what = "bent", level = level, bp = bp, pic = d, t = ray_picture_t(o, dir, d) }
    end
    return { what = "bent", level = level, bp = bp, t = C.ray_box_t(o, dir, bp) }
end

-- Ray (o + t*d, d unit) vs ment id. Pictures: flat disc of radius r in their
-- own plane (normal = frame v2, set when we place them); everything else (and
-- pictures without a frame) = sphere of radius r. Returns t or nil. Things the
-- eye is inside of (skyboxes, auras) are skipped.
local function ray_ment_t(o, d, id, mtype)
    local c = ga_ment_get_lp(id)
    local r = ga_ment_get_radius(id) or 0.5
    if r < 0.3 then r = 0.3 end
    local ox, oy, oz = o.x - c.x, o.y - c.y, o.z - c.z
    if ox * ox + oy * oy + oz * oz <= r * r and not is_picture(mtype) then return nil end
    if is_picture(mtype) then
        local n = nil
        local ok = pcall(function()
            if ga_ment_var_exists(id, "__mesh_fixed_frame_v2") then
                n = ga_ment_get_v(id, "__mesh_fixed_frame_v2")
            end
        end)
        if ok and type(n) == "table" and type(n.x) == "number" then
            local dn = d.x * n.x + d.y * n.y + d.z * n.z
            if math.abs(dn) > 1e-4 then
                local t = -(ox * n.x + oy * n.y + oz * n.z) / dn
                if t < 0 then return nil end
                local hx, hy, hz = ox + d.x * t, oy + d.y * t, oz + d.z * t
                if hx * hx + hy * hy + hz * hz <= r * r then return t end
                return nil
            end
        end
    end
    local b = ox * d.x + oy * d.y + oz * d.z
    local disc = b * b - (ox * ox + oy * oy + oz * oz - r * r)
    if disc < 0 then return nil end
    local s = math.sqrt(disc)
    local t = -b - s
    if t < 0 then t = -b + s end
    if t < 0 then return nil end
    return t
end

-- First trophy block (non-solid, so the look-ray passes through it) along the
-- ray within tmax. 3D DDA over the cells. Returns bp, t or nil.
local function ray_find_trophy(level, o, d, tmax)
    local x, y, z = math.floor(o.x), math.floor(o.y), math.floor(o.z)
    local function axis(p, cell, dir)
        if math.abs(dir) < 1e-9 then return 0, 1e30, 1e30 end
        local step = (dir > 0) and 1 or -1
        local delta = math.abs(1 / dir)
        local first = ((dir > 0) and (cell + 1 - p) or (p - cell)) * delta
        return step, first, delta
    end
    local sx, nx, dx = axis(o.x, x, d.x)
    local sy, ny, dy = axis(o.y, y, d.y)
    local sz, nz, dz = axis(o.z, z, d.z)
    local t = 0
    for _ = 1, 3 * TROPHY_REACH + 3 do
        if t > tmax then return nil end
        local bp = std.bp(x, y, z)
        local ok, name = pcall(ga_block_get, level, bp)
        if ok and name == C.TROPHY_BLOCK then return bp, t end
        if nx <= ny and nx <= nz then x, t, nx = x + sx, nx, nx + dx
        elseif ny <= nz then y, t, ny = y + sy, ny, ny + dy
        else z, t, nz = z + sz, nz, nz + dz end
    end
    return nil
end

function C.crosshair_target()
    local vlevel = ga_get_viewer_level()
    local eye    = ga_get_viewer_offset()
    local look   = C.unit(ga_get_sys_v("game.player.camera.look"))

    -- only things in front of the looked-at block count
    local tmax = REACH
    local blevel, bbp = C.look_target()
    if blevel ~= nil and blevel == vlevel then
        local t = C.ray_box_t(eye, look, bbp)
        if t ~= nil and t < tmax then tmax = t end
    end
    local best = nil
    local function consider(tg)
        if tg.t ~= nil and tg.t <= tmax and (best == nil or tg.t < best.t) then best = tg end
    end

    local half = tmax * 0.5
    local mid = std.vec(eye.x + look.x * half, eye.y + look.y * half, eye.z + look.z * half)

    -- bents (shops, sleep, keys, secret trophies, pictures, ...): their block
    -- cell, or for pictures their rectangle (bigger query: a picture's bent
    -- sits at its centre, up to ~16 blocks from its edge)
    if ga_look_object_bent_exists() then
        local cid = ga_look_object_bent_get_chunk_id()
        if ga_chunk_id_to_level(cid) == vlevel then
            local bp = ga_lbp_to_bp(ga_chunk_id_to_vcp(cid), ga_look_object_bent_get_lbp())
            consider(bent_target(vlevel, eye, look, bp))
        end
    end
    local okb, bents = pcall(ga_bent_sphere_query, vlevel, mid, half + MENT_MARGIN)
    if okb and type(bents) == "table" then
        for _, v in pairs(bents) do
            if v.bp ~= nil then consider(bent_target(vlevel, eye, look, v.bp)) end
        end
    end

    -- ments: the engine's look object (monsters etc.), plus pictures, which
    -- the look object does not reliably report
    if ga_look_object_ment_exists() then
        local id = ga_look_object_ment_inst_id()
        if id ~= nil and id >= 0 and ga_ment_exists(id) and ga_ment_get_level(id) == vlevel then
            local mt = ga_ment_get_type(id)
            if type(mt) == "string" and string.sub(mt, 1, 11) ~= "ment_player" then
                -- the engine says we aim at it, so trust it even up close
                local t = ray_ment_t(eye, look, id, mt)
                    or math.max(0, C.dist3(ga_ment_get_lp(id), eye) - (ga_ment_get_radius(id) or 0.5))
                consider({ what = "ment", id = id, t = t })
            end
        end
    end
    local okm, ments = pcall(ga_ment_sphere_query, vlevel, vlevel - 5, vlevel, mid, half + MENT_MARGIN)
    if okm and type(ments) == "table" then
        for _, v in pairs(ments) do
            local id = v.inst_id
            if id ~= nil and ga_ment_exists(id) and ga_ment_get_level(id) == vlevel then
                local mt = ga_ment_get_type(id)
                if is_picture(mt) then
                    consider({ what = "ment", id = id, t = ray_ment_t(eye, look, id, mt) })
                end
            end
        end
    end

    -- trophy blocks
    local tbp, tt = ray_find_trophy(vlevel, eye, look, math.min(tmax, TROPHY_REACH))
    if tbp ~= nil then consider({ what = "block", level = vlevel, bp = tbp, t = tt }) end

    return best
end

-- What right click removes. Anything on the crosshair first (any hotbar
-- kind); with a non-block slot, otherwise the nearest thing of that slot's
-- family around the aim point (handy for monsters that move).
function C.find_remove_target(kind)
    local tg = C.crosshair_target()
    if tg ~= nil then return tg end
    local fam = C.FAMILY[kind]
    if fam == nil then return nil end
    local level, pos = C.aim_point(0.5)

    if fam == "ment" then
        local best, best_d = nil, 2.5
        local found = ga_ment_sphere_query(level, level - 5, level, pos, 2.5)
        if type(found) == "table" then
            for _, v in pairs(found) do
                local id = v.inst_id
                if id ~= nil and ga_ment_exists(id) and ga_ment_get_level(id) == level then
                    local t = ga_ment_get_type(id)
                    if type(t) == "string" and string.sub(t, 1, 11) ~= "ment_player" then
                        local d = C.dist3(ga_ment_get_lp(id), pos)
                        if d < best_d then best, best_d = id, d end
                    end
                end
            end
        end
        if best ~= nil then return { what = "ment", id = best } end
        return nil
    end

    -- bents (and secret trophies, which are bents)
    local best, best_d = nil, 1e30
    local found = ga_bent_sphere_query(level, pos, 2.0)
    if type(found) == "table" then
        for _, v in pairs(found) do
            if v.bp ~= nil and (v.dist or 0) < best_d then best, best_d = v.bp, (v.dist or 0) end
        end
    end
    if best ~= nil then return { what = "bent", level = level, bp = best, pic = bent_picture(level, best) } end
    return nil
end

function C.remove_target(tg)
    local name = nil
    if tg.what == "ment" then
        name = ga_ment_get_type(tg.id)
        local ok = pcall(ga_ment_remove_perm, tg.id)
        if not ok then ga_ment_remove(tg.id) end
    elseif tg.what == "bent" then
        local ok, t = pcall(ga_bent_get_type, tg.level, tg.bp)
        if ok then name = t end
        if t == C.PIC_BENT then name = "picture" end
        ga_bent_remove_perm(tg.level, tg.bp)
    elseif tg.what == "block" then
        name = "trophy"
        ga_block_change_perm(tg.level, tg.bp, C.AIR)
    end
    if type(name) == "string" and name ~= "" then ga_hud_msg("Removed " .. name, 1.0) end
end

-------------------------------------------------------------------------------
-- "Pink Path" / "Blue Path" hotbar entries (BUFFS tab, kind "path"): L-click
-- does what touching a pink / blue ring does (base/BasicEnts/bent_base_ring_*),
-- starting from the chunk you are in. Calls base's tele modules directly, so
-- no cheat gate (xar's "pink"/"blue" console cheats wrap the same calls).
-------------------------------------------------------------------------------

function C.use_path(raw)
    local cid = ga_get_viewer_chunk_id()
    if raw == "pink" then
        -- grows you to the nearest parent chunk with a pink sphere
        if game_base_tele_pink.get_pink_dest_chunk_id(cid) < 0 then
            ga_hud_msg("Pink Path: no pink sphere above you", 2.0)
        end
        game_base_tele_pink.tele(cid)               -- plays pink_ring / error
    elseif raw == "blue" then
        local tb = game_base_tele_blue
        if tb.get_blue_tele_progress_stage() ~= 0 then return end   -- already going
        -- a failed blue descend calls ga_exit(), so only start when there is a
        -- "down"/"terminal" chunk above you, like a real blue ring would have
        if tb.get_blue_dest_top_chunk_id(cid) < 0 then
            ga_hud_msg("Blue Path: no blue path from here", 2.0)
            ga_play_sound("error")
            return
        end
        tb.start_tele(cid)
        ga_play_sound("blue_ring")
    end
end
