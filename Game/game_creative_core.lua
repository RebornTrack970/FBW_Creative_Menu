-- Creative mode (game side): shared constants, env var setup, the hotbar
-- (+ saving it with the game), build mode binds and aiming helpers.
--
-- How the game_creative*.lua files fit together: the engine runs every file in
-- Game/ in ONE Lua state as `<file> = {}; local p = <file>; <code>`, in an order
-- we don't control, and calls the __load_game / __update_* / __render_augmented
-- hooks of every file. Everything shared lives in the global table creative_g
-- (C) and mutable state in creative_g.state (S); every file grabs them with
-- `x = x or {}` at the top and only looks other files' things up when its
-- functions RUN, never while loading.
creative_g = creative_g or {}           -- shared by all game_creative*.lua files (one game Lua state)
creative_g.state = creative_g.state or {}
local C, S = creative_g, creative_g.state

local SEL_VAR   = "temp.creative.selected_block"
C.MODE_VAR  = "temp.creative.build_mode"
C.SLOT_VAR  = "temp.creative.hb_slot"     -- selected hotbar slot, 1..HB_COUNT
local HB_PREFIX = "temp.creative.hb"          -- hb1..hb9 = "kind|raw" or ""
C.HB_COUNT  = 9
C.DIST_VAR  = "temp.creative.ent_dist"    -- placement distance for non-blocks (Alt + wheel)
C.ALT_VAR   = "temp.creative.alt"         -- Alt currently held (build mode binds LALT/RALT)
C.DIST_MIN, C.DIST_MAX = 1, 60
C.AIR       = "block_e"
C.BIG_TTL   = 60.0 * 60.0 * 24.0 * 365.0
C.TROPHY_BLOCK = "block_xar_trophy"

-- Hotbar entry kinds. Everything that is not "block" is placed at the aim point
-- (DIST ahead, scroll to change) and removed with right click.
--   block   = block type name          ment    = moving ent type (monsters etc.)
--   bent    = basic ent type (shops..)  picture = picture_* texture (ment_picture_*)
--   trophy  = trophy api name           secret  = secret trophy st_* name
C.FAMILY = { ment = "ment", picture = "bent", bent = "bent", secret = "bent", trophy = "trophy" }

function C.ensure_vars()
    ga_init_s(SEL_VAR, "")
    ga_init_b(C.MODE_VAR, false)
    ga_init_s("temp.creative.brush_shape", "single")
    ga_init_i("temp.creative.brush_size", 0)
    ga_init_s("temp.creative.wp_search", "")
    ga_init_i(C.SLOT_VAR, 1)
    for i = 1, C.HB_COUNT do ga_init_s(HB_PREFIX .. i, "") end
    ga_init_i(C.DIST_VAR, 4)
    ga_init_b(C.ALT_VAR, false)
    ga_init_s("temp.creative.area", "")
    ga_init_i("temp.creative.ent_count", 1)
    ga_init_b("temp.creative.ent_freeze", false)
    ga_init_i("temp.creative.ent_ttl", 0)
    ga_init_i("temp.creative.decor_size", 2)
    ga_init_b("temp.creative.decor_snap", true)
    ga_init_s("temp.creative.text_msg", "")
    ga_init_s("temp.creative.text_state", "")
end

function C.enable_cheats()
    -- Intentionally NO-OP. metagame.cheat.enabled is READ ONLY — ga_set_sys_b on
    -- it is a native crash. Cheats are already on via program_startup.txt, and
    -- ga_set_i/ga_set_f writes bypass the cheat gate anyway.
end

-------------------------------------------------------------------------------
-- Hotbar (same var layout as Windows/win_creative.lua, which also writes it)
-------------------------------------------------------------------------------

local function hb_get(i)
    local s = ga_get_s(HB_PREFIX .. i)
    if type(s) ~= "string" or s == "" then return nil, nil end
    local k, r = string.match(s, "^([^|]+)|(.+)$")
    return k, r
end

function C.cur_slot()
    local s = ga_get_i(C.SLOT_VAR) or 1
    if s < 1 or s > C.HB_COUNT then s = 1 end
    return s
end

-- kind, raw of the selected hotbar slot (nil when the slot is empty)
function C.cur_entry()
    local k, r = hb_get(C.cur_slot())
    if k == nil then
        local s = ga_get_s(SEL_VAR)   -- legacy: block set without the hotbar
        if type(s) == "string" and s ~= "" then return "block", s end
    end
    return k, r
end

function C.sync_sel()
    local k, r = hb_get(C.cur_slot())
    ga_set_s(SEL_VAR, (k == "block") and r or "")
end

-- Put an entry on the hotbar: reuse its slot if it is already there, else the
-- current slot if empty, else the first empty slot, else replace the current one.
function C.hb_pick(kind, raw)
    local want = kind .. "|" .. raw
    local slot = C.cur_slot()
    local target = nil
    for i = 1, C.HB_COUNT do
        if ga_get_s(HB_PREFIX .. i) == want then target = i break end
    end
    if target == nil then
        if hb_get(slot) == nil then
            target = slot
        else
            for i = 1, C.HB_COUNT do
                if hb_get(i) == nil then target = i break end
            end
        end
        target = target or slot
        ga_set_s(HB_PREFIX .. target, want)
    end
    ga_set_i(C.SLOT_VAR, target)
    C.sync_sel()
end

-- Hotbar save/load. temp.* vars are never saved, and Lua may only create
-- temp.* env vars, so the hotbar is mirrored into dynamic vars: "dyn.*" names,
-- saved per save in Data/Save/<save>/dyn_vars.txt (base keeps its waypoints
-- the same way). hb_restore() runs in __load_game; hb_mirror() every tick
-- copies any change (game or menu) into them, so a save always has it.
local DYN_HB   = "dyn.creative.hb"          -- dyn.creative.hb1 .. hb9
local DYN_SLOT = "dyn.creative.hb_slot"
S.hb_restored = false

local function dyn_get_s(n) if ga_dyn_exists(n) then return ga_dyn_get_s(n) end return nil end
local function dyn_get_i(n) if ga_dyn_exists(n) then return ga_dyn_get_i(n) end return nil end

function C.hb_restore()
    -- each save has its own hotbar: a save without one starts empty
    for i = 1, C.HB_COUNT do ga_set_s(HB_PREFIX .. i, dyn_get_s(DYN_HB .. i) or "") end
    local slot = dyn_get_i(DYN_SLOT) or 1
    if slot < 1 or slot > C.HB_COUNT then slot = 1 end
    ga_set_i(C.SLOT_VAR, slot)
    C.sync_sel()
end

function C.hb_mirror()
    for i = 1, C.HB_COUNT do
        local n, v = DYN_HB .. i, ga_get_s(HB_PREFIX .. i) or ""
        local cur = dyn_get_s(n)
        -- (no dyn vars at all in saves that never used the hotbar)
        if cur ~= v and not (cur == nil and v == "") then
            if cur == nil then ga_dyn_create_s(n) end
            ga_dyn_set_s(n, v)
        end
    end
    local slot, cur = C.cur_slot(), dyn_get_i(DYN_SLOT)
    if cur ~= slot and not (cur == nil and slot == 1) then
        if cur == nil then ga_dyn_create_i(DYN_SLOT) end
        ga_dyn_set_i(DYN_SLOT, slot)
    end
end

-------------------------------------------------------------------------------
-- Binds. Build mode: L place, R break/remove, MMB/C pick, Backspace undo.
-- The mouse wheel and 1-9 are NOT rebound: the engine does not run anonymous
-- "tocommand" binds on wheel (.use) events. They stay on xar's own actions
-- (equip_right / equip_left / equip N) and hook_equip_commands() below
-- redirects those commands to the hotbar while build mode is on.
-- Off: back to xar's actions (Data/Packages/xar/binds.txt).
-------------------------------------------------------------------------------

-- "toaction" does NOT replace an existing anonymous (tocommand) bind on the
-- same event, so the guns stayed dead after leaving build mode. Unbind first.
local function bind_action(ev, action)
    ga_command('bind ' .. ev .. ' unbind')
    ga_command('bind ' .. ev .. ' toaction ' .. action)
end

local function bind_xar_wheel_and_digits()
    bind_action('MOUSEWHEEL_UP.use', 'PACKAGE_EQUIP_NEXT')
    bind_action('MOUSEWHEEL_DOWN.use', 'PACKAGE_EQUIP_PREV')
    for i = 1, C.HB_COUNT do
        bind_action(i .. '.downup', 'PACKAGE_EQUIP_' .. i)
    end
end

local function bind_build()
    ga_command('bind MOUSE1.downup tocommand "creative_place"')
    ga_command('bind MOUSE2.downup tocommand "creative_break"')
    ga_command('bind MOUSE3.downup tocommand "creative_eyedrop"')
    ga_command('bind C.downup tocommand "creative_eyedrop"')
    ga_command('bind BACKSPACE.downup tocommands "creative_undo start" "creative_undo end"')
    -- Alt held = mouse wheel changes placement distance (xar leaves Alt unbound)
    ga_command('bind LALT.downup tocommands "creative_alt start" "creative_alt stop"')
    ga_command('bind RALT.downup tocommands "creative_alt start" "creative_alt stop"')
    bind_xar_wheel_and_digits()   -- also repairs binds left by older versions
end

local function bind_weapons()
    bind_action('MOUSE1.downup', 'PACKAGE_USE_EQUIPPED_PRIMARY')
    bind_action('MOUSE2.downup', 'PACKAGE_USE_EQUIPPED_SECONDARY')
    bind_action('C.downup', 'PACKAGE_USE_WEP_3_PRIMARY')
    -- unbound in xar by default
    ga_command('bind MOUSE3.downup unbind')
    ga_command('bind BACKSPACE.downup unbind')
    ga_command('bind LALT.downup unbind')
    ga_command('bind RALT.downup unbind')
    bind_xar_wheel_and_digits()
end

function C.set_build_mode(on)
    ga_set_b(C.MODE_VAR, on)
    ga_set_b(C.ALT_VAR, false)
    if on then
        bind_build()
        ga_hud_msg("Creative build: ON  (L-click place / R-click break, wheel / 1-9 = hotbar, Alt+wheel = distance)", 2.5)
    else
        bind_weapons()
        ga_hud_msg("Creative build: OFF  (mouse = weapons)", 2.5)
    end
end

-- Binds are saved by the engine, so after a restart the creative binds can still
-- be active while build mode is off. Handlers call this to put the guns back.
function C.build_mode_or_heal()
    if ga_exists(C.MODE_VAR) and ga_get_b(C.MODE_VAR) then return true end
    bind_weapons()
    return false
end

-------------------------------------------------------------------------------
-- Aiming
-------------------------------------------------------------------------------

-- Looked-at block: level, bp (the block), bp2 (the empty cell on the face you
-- look at). The level is the block's own level, so bp is in that level's coords.
function C.look_target()
    if not ga_look_object_block_exists() then return nil end
    local cid = ga_look_object_block_get_chunk_id()
    local lbp = ga_look_object_block_get_lbp()
    local vcp = ga_chunk_id_to_vcp(cid)
    local bp  = ga_lbp_to_bp(vcp, lbp)
    local level = ga_chunk_id_to_level(cid)
    local bp2 = std.get_adj_bp(bp, ga_look_object_block_get_normal_side())
    return level, bp, bp2
end

-- Ray (o + t*d) vs the unit cube of block bp. Returns entry t or nil.
function C.ray_box_t(o, d, bp)
    local tmin, tmax = -1e30, 1e30
    for _, ax in ipairs({ "x", "y", "z" }) do
        local lo, hi, oa, da = bp[ax], bp[ax] + 1, o[ax], d[ax]
        if math.abs(da) < 1e-9 then
            if oa < lo or oa > hi then return nil end
        else
            local t1, t2 = (lo - oa) / da, (hi - oa) / da
            if t1 > t2 then t1, t2 = t2, t1 end
            if t1 > tmin then tmin = t1 end
            if t2 < tmax then tmax = t2 end
            if tmin > tmax then return nil end
        end
    end
    if tmax < 0 then return nil end
    return math.max(tmin, 0)
end

function C.place_dist()
    local d = ga_get_i(C.DIST_VAR) or 4
    if d < C.DIST_MIN then d = C.DIST_MIN end
    if d > C.DIST_MAX then d = C.DIST_MAX end
    return d
end

-- Where a non-block thing goes: DIST ahead of the camera, but pulled in front of
-- the first solid block on the crosshair so it never ends up inside a wall.
-- hit = { t = distance to that block, n = its face normal } when clamped.
function C.aim_point(pullback)
    local level = ga_get_viewer_level()
    local eye   = ga_get_viewer_offset()
    local look  = ga_get_sys_v("game.player.camera.look")
    local d     = C.place_dist()
    local hit   = nil
    local blevel, bp, bp2 = C.look_target()
    if blevel ~= nil and blevel == level then
        local t = C.ray_box_t(eye, look, bp)
        if t ~= nil and t - pullback < d then
            d = math.max(0.25, t - pullback)
            hit = { t = t, n = std.vec(bp2.x - bp.x, bp2.y - bp.y, bp2.z - bp.z) }
        end
    end
    local pos = std.vec(eye.x + look.x * d, eye.y + look.y * d, eye.z + look.z * d)
    return level, pos, look, hit, eye
end

function C.dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function C.unit(v)
    local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if len < 1e-9 then return std.vec(0, 0, 1) end
    return std.vec(v.x / len, v.y / len, v.z / len)
end
